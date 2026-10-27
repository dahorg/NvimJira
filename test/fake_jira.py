"""Minimal fake Jira Cloud API for the lazygit-jira tests.

Usage: python3 fake_jira.py PORT_FILE LOG_FILE

Accepts Basic auth for test@example.com:secret-token only and answers
/rest/api/3/myself and /rest/api/3/search/jql. Writes the chosen port to
PORT_FILE and one JSON line per request (path, query, auth_ok) to LOG_FILE.
"""

import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

EMAIL = "test@example.com"
TOKEN = "secret-token"
EXPECTED_AUTH = "Basic " + base64.b64encode(f"{EMAIL}:{TOKEN}".encode()).decode()

ISSUES = [
    ("PL-250", "In Progress", "Bug", "Login fails on Safari"),
    ("PL-237", "Waiting", "Task", "Follow up on security review"),
]


def issue(key, status, issuetype, summary):
    return {
        "key": key,
        "fields": {
            "summary": summary,
            "status": {"name": status},
            "issuetype": {"name": issuetype},
            "assignee": {"displayName": "Test User"},
        },
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        auth_ok = self.headers.get("Authorization") == EXPECTED_AUTH
        with open(sys.argv[2], "a") as log:
            log.write(json.dumps({"path": url.path, "query": parse_qs(url.query), "auth_ok": auth_ok}) + "\n")

        if not auth_ok:
            return self.reply(401, {"errorMessages": ["Client must be authenticated to access this resource."]})
        if url.path == "/rest/api/3/myself":
            return self.reply(200, {"displayName": "Test User", "emailAddress": EMAIL})
        if url.path == "/rest/api/3/search/jql":
            return self.reply(200, {"issues": [issue(*i) for i in ISSUES]})
        self.reply(404, {"errorMessages": ["Not found: " + url.path]})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
