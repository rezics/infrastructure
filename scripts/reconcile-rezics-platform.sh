#!/usr/bin/env bash

set -euo pipefail
umask 077

readonly management_token_file="${REZICS_NOMAD_MANAGEMENT_TOKEN_FILE:?}"
readonly outline_app_job_file="${REZICS_OUTLINE_APP_JOB_FILE:?}"
readonly outline_db_job_file="${REZICS_OUTLINE_DB_JOB_FILE:?}"
readonly signoz_store_job_file="${REZICS_SIGNOZ_STORE_JOB_FILE:?}"
readonly signoz_core_job_file="${REZICS_SIGNOZ_CORE_JOB_FILE:?}"
readonly signoz_agent_job_file="${REZICS_SIGNOZ_AGENT_JOB_FILE:?}"
readonly signoz_tokenizer_jwt_secret_file="${REZICS_SIGNOZ_TOKENIZER_JWT_SECRET_FILE:?}"
readonly signoz_root_email_file="${REZICS_SIGNOZ_ROOT_EMAIL_FILE:?}"
readonly signoz_root_password_file="${REZICS_SIGNOZ_ROOT_PASSWORD_FILE:?}"
readonly signoz_root_org_name_file="${REZICS_SIGNOZ_ROOT_ORG_NAME_FILE:?}"
readonly signoz_root_org_id_file="${REZICS_SIGNOZ_ROOT_ORG_ID_FILE:?}"

for required_file in \
	"${management_token_file}" \
	"${outline_app_job_file}" \
	"${outline_db_job_file}" \
	"${signoz_store_job_file}" \
	"${signoz_core_job_file}" \
	"${signoz_agent_job_file}" \
	"${signoz_tokenizer_jwt_secret_file}" \
	"${signoz_root_email_file}" \
	"${signoz_root_password_file}" \
	"${signoz_root_org_name_file}" \
	"${signoz_root_org_id_file}"; do
	if [[ ! -r "${required_file}" ]]; then
		printf 'Required platform input is missing: %s\n' "${required_file}" >&2
		exit 1
	fi
done

export NOMAD_ADDR="https://127.0.0.1:4646"
export NOMAD_TLS_SERVER_NAME="server.global.nomad"
export NOMAD_NAMESPACE="default"
management_token="$(<"${management_token_file}")"
export NOMAD_TOKEN="${management_token}"

jq -n \
	--rawfile tokenizer_jwt_secret "${signoz_tokenizer_jwt_secret_file}" \
	--rawfile root_email "${signoz_root_email_file}" \
	--rawfile root_password "${signoz_root_password_file}" \
	--rawfile root_org_name "${signoz_root_org_name_file}" \
	--rawfile root_org_id "${signoz_root_org_id_file}" '
	def value: rtrimstr("\n");
	{
		Namespace: "rezics-infrastructure",
		Path: "nomad/jobs/signoz-core",
		Items: {
			SIGNOZ_TOKENIZER_JWT_SECRET: ($tokenizer_jwt_secret | value),
			SIGNOZ_USER_ROOT_EMAIL: ($root_email | value),
			SIGNOZ_USER_ROOT_PASSWORD: ($root_password | value),
			SIGNOZ_USER_ROOT_ORG_NAME: ($root_org_name | value),
			SIGNOZ_USER_ROOT_ORG_ID: ($root_org_id | value)
		}
	}
' | nomad var put -force -in=json -out=none -

nomad job run -no-color -detach -namespace=default "${outline_db_job_file}"
nomad job run -no-color -detach -namespace=default "${outline_app_job_file}"
nomad job run -no-color -detach -namespace=rezics-infrastructure "${signoz_store_job_file}"
nomad job run -no-color -detach -namespace=rezics-infrastructure "${signoz_core_job_file}"
nomad job run -no-color -detach -namespace=rezics-infrastructure "${signoz_agent_job_file}"
printf '%s\n' "Outline, SigNoz storage/core, and host-agent jobs reconciled"
