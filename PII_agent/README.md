# PII Agent

`PII_agent` is the standalone Presidio-based PII detection and anonymization service for Ultibot.

## Structure

- `backend/`: FastAPI service used by the web app and backend integrations.
- `frontend/`: shared frontend helper that calls the PII API.

## Local development

1. Install the Python dependencies:
   `cd PII_agent/backend && pip install -r requirements.txt`
2. Run the API locally:
   `uvicorn main:app --host 127.0.0.1 --port 8000 --reload`
3. Point the main backend at the service:
   `PiiService__BaseUrl=http://127.0.0.1:8000`
4. Run the main backend and frontend as usual. The browser now calls `/api/pii/*` on the main API, and the backend proxies those requests to this service.

## Docker

Build:
`docker build -f PII_agent/backend/Dockerfile -t ultibot/pii-agent .`

Run:
`docker run --rm -p 10000:10000 -e PORT=10000 -e PII_SERVICE_CORS_ORIGINS=https://your-frontend.example.com ultibot/pii-agent`

## Render deployment

Deploy this service as a Private Service in the same Render workspace as your main API.

- Root directory: leave empty
- Environment: `Docker`
- Dockerfile path: `PII_agent/backend/Dockerfile`
- Service type: `Private Service`
- Internal port: set `PORT=8000`
- Instance type: start with at least a plan that can handle the spaCy model memory footprint

Set these environment variables on the PII private service:

- `HOST=0.0.0.0`
- `PORT=8000`
- `PII_SERVICE_RELOAD=false`

Then update the main API deployment environment:

- `PiiService__BaseUrl=http://your-pii-private-service:8000`

The frontend no longer needs a public `VITE_PII_SERVICE_URL`. It calls the main API, and the main API reaches the private PII service over Render's internal network.
