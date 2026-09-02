package main

import (
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func jwtForClaims(t *testing.T, claims map[string]any) string {
	t.Helper()
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	return "header." + base64.RawURLEncoding.EncodeToString(payload) + ".signature"
}

func validClaims(selected pipeline) map[string]any {
	claims := map[string]any{
		"iss":                 expectedIssuer,
		"aud":                 selected.audience,
		"repository":          expectedRepository,
		"repository_id":       expectedRepositoryID,
		"repository_owner_id": expectedRepositoryOwnerID,
		"runner_environment":  "github-hosted",
		"environment":         selected.environment,
		"workflow_ref":        expectedRepository + "/" + selected.workflow + "@refs/heads/main",
		"sha":                 strings.Repeat("a", 40),
		"run_id":              "123",
		"run_attempt":         "1",
	}
	claims["event_name"] = "push"
	claims["ref"] = "refs/tags/v1.2.3"
	claims["ref_type"] = "tag"
	claims["workflow_ref"] = expectedRepository + "/" + selected.workflow + "@refs/tags/v1.2.3"
	return claims
}

func TestDecodeAndValidateReleaseClaims(t *testing.T) {
	selected := pipelines["/v1/releases/dispatch"]
	decoded, err := decodeClaims(jwtForClaims(t, validClaims(selected)))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateClaims(decoded, selected); err != nil {
		t.Fatalf("valid claims rejected: %v", err)
	}
}

func TestValidateClaimsRejectsWrongRepositoryID(t *testing.T) {
	selected := pipelines["/v1/releases/dispatch"]
	claims := validClaims(selected)
	claims["repository_id"] = "1"
	decoded, err := decodeClaims(jwtForClaims(t, claims))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateClaims(decoded, selected); err == nil {
		t.Fatal("wrong repository ID was accepted")
	}
}

func TestValidateClaimsRejectsMissingOrWrongEnvironment(t *testing.T) {
	selected := pipelines["/v1/releases/dispatch"]
	for name, environment := range map[string]any{
		"missing": nil,
		"wrong":   "staging",
	} {
		t.Run(name, func(t *testing.T) {
			claims := validClaims(selected)
			if environment == nil {
				delete(claims, "environment")
			} else {
				claims["environment"] = environment
			}
			decoded, err := decodeClaims(jwtForClaims(t, claims))
			if err != nil {
				t.Fatal(err)
			}
			if err := validateClaims(decoded, selected); err == nil {
				t.Fatalf("environment %#v was accepted", environment)
			}
		})
	}
}

func TestValidateClaimsRejectsPrereleaseTag(t *testing.T) {
	selected := pipelines["/v1/releases/dispatch"]
	claims := validClaims(selected)
	claims["ref"] = "refs/tags/v1.2.3-rc.1"
	decoded, err := decodeClaims(jwtForClaims(t, claims))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateClaims(decoded, selected); err == nil {
		t.Fatal("prerelease tag was accepted")
	}
}

func TestBearerToken(t *testing.T) {
	if token, err := bearerToken("Bearer header.payload.signature"); err != nil || token != "header.payload.signature" {
		t.Fatalf("valid token rejected: %q, %v", token, err)
	}
	if _, err := bearerToken("Basic value"); err == nil {
		t.Fatal("non-bearer authorization was accepted")
	}
}

func TestSetNomadBlockingQueryWait(t *testing.T) {
	tests := map[string]struct {
		url        string
		expectWait string
	}{
		"adds bounded wait to blocking query": {
			url:        "/v1/jobs/statuses?filter=&index=91277",
			expectWait: nomadBlockingQueryWait,
		},
		"preserves explicit wait": {
			url:        "/v1/jobs/statuses?index=91277&wait=10s",
			expectWait: "10s",
		},
		"does not alter ordinary request": {
			url: "/v1/jobs/statuses?filter=running",
		},
	}

	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, test.url, nil)
			setNomadBlockingQueryWait(request)
			if wait := request.URL.Query().Get("wait"); wait != test.expectWait {
				t.Fatalf("wait = %q, want %q", wait, test.expectWait)
			}
		})
	}
}

func TestDispatchReturnsAcceptedWithoutMonitoring(t *testing.T) {
	selected := pipelines["/v1/releases/dispatch"]
	jwt := jwtForClaims(t, validClaims(selected))
	nomad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/v1/acl/login":
			json.NewEncoder(w).Encode(loginResponse{SecretID: "short-lived"})
		case "/v1/job/rezics-release/dispatch":
			if request.Header.Get("X-Nomad-Token") != "short-lived" {
				t.Error("dispatch did not use the Nomad login token")
			}
			json.NewEncoder(w).Encode(dispatchResponse{
				DispatchedJobID: "rezics-release/dispatch-1",
				EvalID:          "eval-1",
			})
		default:
			http.NotFound(w, request)
		}
	}))
	defer nomad.Close()

	app := &gateway{
		nomadAddress: nomad.URL,
		httpClient:   nomad.Client(),
		logger:       slog.New(slog.NewTextHandler(os.Stderr, nil)),
	}
	request := httptest.NewRequest(http.MethodPost, selected.path, nil)
	request.Header.Set("Authorization", "Bearer "+jwt)
	response := httptest.NewRecorder()
	app.dispatch(response, request, selected)

	if response.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", response.Code, response.Body.String())
	}
	var receipt acceptedResponse
	if err := json.NewDecoder(response.Body).Decode(&receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Status != "accepted" || receipt.JobID != "rezics-release/dispatch-1" || receipt.EvalID != "eval-1" {
		t.Fatalf("unexpected receipt: %#v", receipt)
	}
}

func TestRoutesRejectTimelineGets(t *testing.T) {
	app := &gateway{
		logger: slog.New(slog.NewTextHandler(os.Stderr, nil)),
	}
	for _, path := range []string{
		"/v1/releases/dispatch?job_id=rezics-release/dispatch-1-token&eval_id=eval-1",
		"/v1/releases/timeline?job_id=rezics-release/dispatch-1-token&eval_id=eval-1",
	} {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		response := httptest.NewRecorder()
		app.routes().ServeHTTP(response, request)
		if response.Code != http.StatusMethodNotAllowed && response.Code != http.StatusNotFound {
			t.Fatalf("GET %s returned %d, want 404 or 405", path, response.Code)
		}
	}
}
