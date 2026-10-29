#!/bin/bash
set -e

psql \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set ON_ERROR_STOP=1 \
  --set jira_password="$JIRA_DB_PASSWORD" \
  --set confluence_password="$CONFLUENCE_DB_PASSWORD" \
  --set bitbucket_password="$BITBUCKET_DB_PASSWORD" <<'SQL'
CREATE ROLE jira_user LOGIN PASSWORD :'jira_password';
CREATE DATABASE jira OWNER jira_user;

CREATE ROLE confluence_user LOGIN PASSWORD :'confluence_password';
CREATE DATABASE confluence OWNER confluence_user;

CREATE ROLE bitbucket_user LOGIN PASSWORD :'bitbucket_password';
CREATE DATABASE bitbucket OWNER bitbucket_user;
SQL
