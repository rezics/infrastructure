package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	expectedRepository        = "rezics/rezics"
	expectedRepositoryID      = "994100138"
	expectedRepositoryOwnerID = "92638361"
	expectedIssuer            = "https://token.actions.githubusercontent.com"
)

var (
	commitPattern     = regexp.MustCompile(`^[0-9a-f]{40}$`)
	digitsPattern     = regexp.MustCompile(`^[1-9][0-9]*$`)
	releaseTagPattern = regexp.MustCompile(`^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$`)
)

const (
	nomadBlockingQueryWait     = "20s"
	nomadResponseHeaderTimeout = 30 * time.Second
)

type pipeline struct {
	path        string
	kind        string
	authMethod  string
	audience    string
	environment string
	namespace   string
	parentJob   string
	workflow    string
}

var pipelines = map[string]pipeline{
	"/v1/releases/dispatch": {
		path:        "/v1/releases/dispatch",
		kind:        "release",
		authMethod:  "github-release",
		audience:    "rezics-nomad-release",
		environment: "production",
		namespace:   "rezics-release",
		parentJob:   "rezics-release",
		workflow:    ".github/workflows/release.yml",
	},
}

type config struct {
	listenAddress   string
	adminAddress    string
	adminUsername   string
	adminPassword   string
	adminNomadToken string
	nomadAddress    string
	nomadCAFile     string
	nomadCertFile   string
	nomadKeyFile    string
	nomadServerName string
}

type gateway struct {
	nomadAddress string
	httpClient   *http.Client
	logger       *slog.Logger
}

type githubClaims struct {
	Issuer            string
	Audience          string
	Repository        string
	RepositoryID      string
	RepositoryOwnerID string
	RunnerEnvironment string
	Environment       string
	WorkflowRef       string
	EventName         string
	Ref               string
	RefType           string
	SHA               string
	RunID             string
	RunAttempt        string
	Actor             string
}

type loginResponse struct {
	SecretID       string    `json:"SecretID"`
	ExpirationTime time.Time `json:"ExpirationTime"`
}

type dispatchResponse struct {
	DispatchedJobID string `json:"DispatchedJobID"`
	EvalID          string `json:"EvalID"`
	EvalCreateIndex uint64 `json:"EvalCreateIndex"`
}

type acceptedResponse struct {
	Status string `json:"status"`
	JobID  string `json:"job_id"`
	EvalID string `json:"eval_id"`
	SHA    string `json:"sha"`
	Ref    string `json:"ref"`
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := loadConfig()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	client, err := newNomadHTTPClient(cfg)
	if err != nil {
		logger.Error("cannot configure Nomad client", "error", err)
		os.Exit(1)
	}

	app := &gateway{
		nomadAddress: strings.TrimRight(cfg.nomadAddress, "/"),
		httpClient:   client,
		logger:       logger,
	}
	adminHandler, err := app.adminProxy(cfg)
	if err != nil {
		logger.Error("cannot configure Nomad admin proxy", "error", err)
		os.Exit(1)
	}
	adminServer := &http.Server{
		Addr:              cfg.adminAddress,
		Handler:           adminHandler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       75 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	go func() {
		logger.Info("Nomad admin proxy listening", "address", cfg.adminAddress)
		if err := adminServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("Nomad admin proxy stopped", "error", err)
			os.Exit(1)
		}
	}()

	server := &http.Server{
		Addr:              cfg.listenAddress,
		Handler:           app.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       75 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	logger.Info("release gateway listening", "address", cfg.listenAddress)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("release gateway stopped", "error", err)
		os.Exit(1)
	}
}

func loadConfig() (config, error) {
	cfg := config{
		listenAddress:   envOrDefault("REZICS_GATEWAY_LISTEN", "127.0.0.1:20242"),
		adminAddress:    envOrDefault("REZICS_NOMAD_ADMIN_LISTEN", "127.0.0.1:20243"),
		nomadAddress:    envOrDefault("NOMAD_ADDR", "https://127.0.0.1:4646"),
		nomadCAFile:     os.Getenv("NOMAD_CACERT"),
		nomadCertFile:   os.Getenv("NOMAD_CLIENT_CERT"),
		nomadKeyFile:    os.Getenv("NOMAD_CLIENT_KEY"),
		nomadServerName: envOrDefault("NOMAD_TLS_SERVER_NAME", "server.global.nomad"),
	}
	if cfg.nomadAddress == "" {
		return config{}, errors.New("NOMAD_ADDR is required")
	}
	parsed, err := url.Parse(cfg.nomadAddress)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return config{}, errors.New("NOMAD_ADDR must be an absolute HTTP(S) URL")
	}
	if parsed.Scheme == "https" && (cfg.nomadCAFile == "" || cfg.nomadCertFile == "" || cfg.nomadKeyFile == "") {
		return config{}, errors.New("Nomad CA, client certificate, and client key are required for HTTPS")
	}
	if cfg.adminUsername, err = readCredential("REZICS_NOMAD_ADMIN_USERNAME_FILE"); err != nil {
		return config{}, err
	}
	if cfg.adminPassword, err = readCredential("REZICS_NOMAD_ADMIN_PASSWORD_FILE"); err != nil {
		return config{}, err
	}
	if cfg.adminNomadToken, err = readCredential("REZICS_NOMAD_ADMIN_TOKEN_FILE"); err != nil {
		return config{}, err
	}
	return cfg, nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func readCredential(environmentName string) (string, error) {
	path := os.Getenv(environmentName)
	if path == "" {
		return "", fmt.Errorf("%s is required", environmentName)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", environmentName, err)
	}
	value := strings.TrimSpace(string(content))
	if value == "" {
		return "", fmt.Errorf("%s is empty", environmentName)
	}
	return value, nil
}

func newNomadHTTPClient(cfg config) (*http.Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ResponseHeaderTimeout = nomadResponseHeaderTimeout
	transport.IdleConnTimeout = 90 * time.Second
	if strings.HasPrefix(cfg.nomadAddress, "https://") {
		caPEM, err := os.ReadFile(cfg.nomadCAFile)
		if err != nil {
			return nil, fmt.Errorf("read Nomad CA: %w", err)
		}
		roots := x509.NewCertPool()
		if !roots.AppendCertsFromPEM(caPEM) {
			return nil, errors.New("Nomad CA contains no certificates")
		}
		certificate, err := tls.LoadX509KeyPair(cfg.nomadCertFile, cfg.nomadKeyFile)
		if err != nil {
			return nil, fmt.Errorf("load Nomad client certificate: %w", err)
		}
		transport.TLSClientConfig = &tls.Config{
			MinVersion:   tls.VersionTLS13,
			RootCAs:      roots,
			Certificates: []tls.Certificate{certificate},
			ServerName:   cfg.nomadServerName,
		}
	}
	return &http.Client{Transport: transport}, nil
}

func (g *gateway) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	for path, selected := range pipelines {
		current := selected
		mux.HandleFunc("POST "+path, func(w http.ResponseWriter, r *http.Request) {
			g.dispatch(w, r, current)
		})
	}
	return mux
}

func (g *gateway) adminProxy(cfg config) (http.Handler, error) {
	target, err := url.Parse(g.nomadAddress)
	if err != nil {
		return nil, err
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = g.httpClient.Transport
	originalDirector := proxy.Director
	proxy.Director = func(request *http.Request) {
		originalDirector(request)
		setNomadBlockingQueryWait(request)
		request.Header.Del("Authorization")
		request.Header.Set("X-Nomad-Token", cfg.adminNomadToken)
		request.Header.Set("X-Forwarded-Proto", "https")
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, proxyErr error) {
		g.logger.Error("Nomad admin proxy failed", "error", proxyErr)
		http.Error(w, "Nomad is unavailable", http.StatusBadGateway)
	}
	expectedUsername := sha256.Sum256([]byte(cfg.adminUsername))
	expectedPassword := sha256.Sum256([]byte(cfg.adminPassword))
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		username, password, ok := request.BasicAuth()
		actualUsername := sha256.Sum256([]byte(username))
		actualPassword := sha256.Sum256([]byte(password))
		if !ok || subtle.ConstantTimeCompare(actualUsername[:], expectedUsername[:]) != 1 || subtle.ConstantTimeCompare(actualPassword[:], expectedPassword[:]) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="REZICS Nomad Administration", charset="UTF-8"`)
			http.Error(w, "authentication required", http.StatusUnauthorized)
			return
		}
		proxy.ServeHTTP(w, request)
	}), nil
}

func setNomadBlockingQueryWait(request *http.Request) {
	query := request.URL.Query()
	if query.Get("index") == "" || query.Get("wait") != "" {
		return
	}
	query.Set("wait", nomadBlockingQueryWait)
	request.URL.RawQuery = query.Encode()
}

func (g *gateway) dispatch(w http.ResponseWriter, r *http.Request, selected pipeline) {
	if r.ContentLength > 0 {
		http.Error(w, "request body is not accepted", http.StatusBadRequest)
		return
	}
	jwt, err := bearerToken(r.Header.Get("Authorization"))
	if err != nil {
		http.Error(w, "a GitHub OIDC bearer token is required", http.StatusUnauthorized)
		return
	}

	login, err := g.login(r.Context(), selected.authMethod, jwt)
	if err != nil {
		g.logger.Warn("Nomad rejected GitHub identity", "pipeline", selected.kind, "error", err)
		http.Error(w, "GitHub identity was rejected", http.StatusUnauthorized)
		return
	}
	claims, err := decodeClaims(jwt)
	if err != nil {
		http.Error(w, "GitHub token claims are invalid", http.StatusUnauthorized)
		return
	}
	if err := validateClaims(claims, selected); err != nil {
		g.logger.Warn("GitHub claims do not match dispatch", "pipeline", selected.kind, "error", err)
		http.Error(w, "GitHub token is not authorized for this pipeline", http.StatusForbidden)
		return
	}

	dispatched, err := g.dispatchJob(r.Context(), login.SecretID, selected, claims)
	if err != nil {
		g.logger.Error("Nomad dispatch failed", "pipeline", selected.kind, "run_id", claims.RunID, "error", err)
		http.Error(w, "Nomad could not dispatch the pipeline", http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusAccepted)
	if err := json.NewEncoder(w).Encode(acceptedResponse{
		Status: "accepted",
		JobID:  dispatched.DispatchedJobID,
		EvalID: dispatched.EvalID,
		SHA:    claims.SHA,
		Ref:    claims.Ref,
	}); err != nil {
		g.logger.Warn("cannot encode dispatch receipt", "job_id", dispatched.DispatchedJobID, "error", err)
	}
}

func bearerToken(header string) (string, error) {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return "", errors.New("missing bearer prefix")
	}
	token := strings.TrimSpace(strings.TrimPrefix(header, prefix))
	if token == "" || len(token) > 12<<10 || strings.ContainsAny(token, " \t\r\n") {
		return "", errors.New("invalid bearer token")
	}
	return token, nil
}

func (g *gateway) login(ctx context.Context, method, jwt string) (loginResponse, error) {
	body, err := json.Marshal(map[string]string{"AuthMethodName": method, "LoginToken": jwt})
	if err != nil {
		return loginResponse{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, g.nomadAddress+"/v1/acl/login", strings.NewReader(string(body)))
	if err != nil {
		return loginResponse{}, err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := g.httpClient.Do(request)
	if err != nil {
		return loginResponse{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		io.Copy(io.Discard, io.LimitReader(response.Body, 4<<10))
		return loginResponse{}, fmt.Errorf("Nomad login returned %s", response.Status)
	}
	var result loginResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&result); err != nil {
		return loginResponse{}, err
	}
	if result.SecretID == "" {
		return loginResponse{}, errors.New("Nomad login returned no ACL token")
	}
	return result, nil
}

func decodeClaims(jwt string) (githubClaims, error) {
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		return githubClaims{}, errors.New("JWT must have three segments")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return githubClaims{}, errors.New("JWT payload is not base64url")
	}
	var raw map[string]any
	decoder := json.NewDecoder(strings.NewReader(string(payload)))
	decoder.UseNumber()
	if err := decoder.Decode(&raw); err != nil {
		return githubClaims{}, errors.New("JWT payload is not JSON")
	}
	claim := func(name string) string {
		value, ok := raw[name].(string)
		if !ok {
			return ""
		}
		return value
	}
	audience := claim("aud")
	if audience == "" {
		if values, ok := raw["aud"].([]any); ok && len(values) == 1 {
			audience, _ = values[0].(string)
		}
	}
	return githubClaims{
		Issuer:            claim("iss"),
		Audience:          audience,
		Repository:        claim("repository"),
		RepositoryID:      claim("repository_id"),
		RepositoryOwnerID: claim("repository_owner_id"),
		RunnerEnvironment: claim("runner_environment"),
		Environment:       claim("environment"),
		WorkflowRef:       claim("workflow_ref"),
		EventName:         claim("event_name"),
		Ref:               claim("ref"),
		RefType:           claim("ref_type"),
		SHA:               claim("sha"),
		RunID:             claim("run_id"),
		RunAttempt:        claim("run_attempt"),
		Actor:             claim("actor"),
	}, nil
}

func validateClaims(claims githubClaims, selected pipeline) error {
	checks := []struct {
		actual   string
		expected string
		name     string
	}{
		{claims.Issuer, expectedIssuer, "issuer"},
		{claims.Audience, selected.audience, "audience"},
		{claims.Repository, expectedRepository, "repository"},
		{claims.RepositoryID, expectedRepositoryID, "repository_id"},
		{claims.RepositoryOwnerID, expectedRepositoryOwnerID, "repository_owner_id"},
		{claims.RunnerEnvironment, "github-hosted", "runner_environment"},
		{claims.Environment, selected.environment, "environment"},
	}
	for _, check := range checks {
		if check.actual != check.expected {
			return fmt.Errorf("%s does not match", check.name)
		}
	}
	workflowPrefix := expectedRepository + "/" + selected.workflow + "@"
	if !strings.HasPrefix(claims.WorkflowRef, workflowPrefix) {
		return errors.New("workflow_ref does not match")
	}
	if !commitPattern.MatchString(claims.SHA) || !digitsPattern.MatchString(claims.RunID) || !digitsPattern.MatchString(claims.RunAttempt) {
		return errors.New("run identity is malformed")
	}

	switch selected.kind {
	case "release":
		if claims.EventName != "push" || claims.RefType != "tag" || !releaseTagPattern.MatchString(claims.Ref) {
			return errors.New("release event is not a stable semantic tag")
		}
	default:
		return errors.New("unknown pipeline")
	}
	return nil
}

func (g *gateway) dispatchJob(ctx context.Context, token string, selected pipeline, claims githubClaims) (dispatchResponse, error) {
	metadata := map[string]string{
		"repository":  claims.Repository,
		"sha":         claims.SHA,
		"ref":         claims.Ref,
		"run_id":      claims.RunID,
		"run_attempt": claims.RunAttempt,
		"event_name":  claims.EventName,
	}
	if claims.Actor != "" {
		metadata["actor"] = claims.Actor
	}
	body, err := json.Marshal(map[string]any{"Meta": metadata})
	if err != nil {
		return dispatchResponse{}, err
	}
	idempotencySource := selected.kind + ":" + claims.RepositoryID + ":" + claims.RunID + ":" + claims.RunAttempt
	idempotencyDigest := sha256.Sum256([]byte(idempotencySource))
	query := url.Values{
		"namespace":         []string{selected.namespace},
		"idempotency_token": []string{hex.EncodeToString(idempotencyDigest[:])},
	}
	endpoint := fmt.Sprintf("%s/v1/job/%s/dispatch?%s", g.nomadAddress, url.PathEscape(selected.parentJob), query.Encode())
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(body)))
	if err != nil {
		return dispatchResponse{}, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Nomad-Token", token)
	response, err := g.httpClient.Do(request)
	if err != nil {
		return dispatchResponse{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 4<<10))
		return dispatchResponse{}, fmt.Errorf("Nomad dispatch returned %s: %s", response.Status, strings.TrimSpace(string(message)))
	}
	var result dispatchResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&result); err != nil {
		return dispatchResponse{}, err
	}
	if result.DispatchedJobID == "" || result.EvalID == "" {
		return dispatchResponse{}, errors.New("Nomad dispatch response is incomplete")
	}
	return result, nil
}
