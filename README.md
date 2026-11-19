# HackJudge

### The High-Performance Evaluation Engine for Hackathons & Pitch Competitions

**Evaluate Smarter. Judge Faster. Build Better Competitions.**

[Live Demo](https://hack-judge-final.vercel.app/) | [Docker Hub](https://hub.docker.com/repository/docker/mrsupreme/hackjudge) | [Report Issues](https://github.com/GURUBAKSHYADAV-71218/HackJudge/issues)

---

## Overview

**HackJudge** is a modern, high-performance judging and evaluation platform designed to streamline hackathons, startup pitch competitions, and academic evaluation events.

Traditional competition judging often relies on spreadsheets, manual score calculations, and disconnected communication between organizers and judges.

HackJudge replaces this fragmented workflow with a centralized digital evaluation system that enables organizers to manage competitions, assign judging panels, define scoring criteria, and calculate results efficiently.

Built with a focus on performance, usability, and database-level security, HackJudge delivers a seamless experience for both organizers and judges.

## Key Features

| Feature | Description |
|---|---|
| Modern UI/UX | Premium interface with Light and Dark themes, smooth transitions, and responsive layouts. |
| Secure Authentication | Google OAuth authentication powered by Supabase Auth. |
| Judge Account Claiming | Judges securely claim assigned judging responsibilities using their verified email accounts. |
| Dynamic Round Builder | Create custom evaluation rounds with configurable scoring criteria and weighted averages. |
| Panel Management | Assign specific teams and competition tracks to designated judging panels. |
| Automated Results | Organizer dashboards calculate results from completed judge submissions. |
| Database Security | Supabase Row Level Security (RLS) policies enforce organizer and judge-specific access restrictions. |
| Bulk CSV Import | Import large numbers of participating teams through CSV uploads. |

## Technology Stack

| Layer | Technologies |
|---|---|
| Frontend | React 19, Vite |
| Styling | Vanilla CSS, CSS Variables |
| State Management | TanStack React Query |
| Backend & Database | Supabase, PostgreSQL |
| Authentication | Supabase Auth, Google OAuth |
| Security | PostgreSQL RLS Policies |
| Icons | Lucide React |
| Deployment | Vercel |
| Containerization | Docker |

## Getting Started

Follow these steps to run HackJudge locally.

### Prerequisites

- Node.js and npm
- A Supabase account and project
- Google Cloud project with OAuth credentials

### 1. Clone the Repository

```bash
git clone https://github.com/GURUBAKSHYADAV-71218/HackJudge.git
cd HackJudge
```

### 2. Install Dependencies

```bash
npm install
```

### 3. Configure Environment Variables

Create a `.env` file in the project root:

```env
VITE_SUPABASE_URL=https://your-project-id.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-public-key
```

Replace the placeholder values with your Supabase project credentials.

**Security Note:** Never expose your Supabase service role key or other privileged secrets in frontend environment variables.

### 4. Configure the Database

For a new, empty Supabase project using the core email-account judge flow:

1. Open your Supabase Dashboard.
2. Navigate to SQL Editor.
3. Execute `HACKJUDGE_CORE_SCHEMA.sql` once.
4. Configure the Google OAuth provider in Supabase.
5. Configure the corresponding Web OAuth client in Google Cloud.

**Important:** Do not execute the core schema against an existing database. Existing-project upgrades require a separately reviewed migration process.

### 5. Start the Development Server

```bash
npm run dev
```

Open the application:

```text
http://localhost:5173
```

## Authentication Workflow

HackJudge uses Supabase Auth with Google OAuth.

The current authentication workflow:

1. Organizers sign in using their Google accounts.
2. Organizers create competition events and assign judges using their email addresses.
3. Judges sign in using Google with the same assigned email address.
4. The platform automatically claims the corresponding judge assignment.
5. Judges evaluate their assigned teams and submit scores.
6. Organizers review submissions and access calculated results.

**Note:** Judge magic-link invitations are currently paused. The platform uses verified Supabase Auth accounts for judge assignment claiming.

## Docker

HackJudge has a Docker repository available on Docker Hub.

**Docker Repository:** [mrsupreme/hackjudge](https://hub.docker.com/repository/docker/mrsupreme/hackjudge)

Visit Docker Hub for available image tags and container usage instructions.

## Deployment

HackJudge is configured for deployment on Vercel.

1. Push your repository to GitHub.
2. Import the repository into Vercel.
3. Configure the following environment variables:

```env
VITE_SUPABASE_URL=your-supabase-project-url
VITE_SUPABASE_ANON_KEY=your-supabase-anon-key
```

4. Deploy the application.

The included `vercel.json` handles Single Page Application (SPA) routing.

**Live Application:** [https://hack-judge-final.vercel.app/](https://hack-judge-final.vercel.app/)

## CI/CD Quality Gates

The project integrates two CI/CD add-ons on top of the existing checks (lint, unit tests, Supabase schema/RLS smoke tests):

| Tool | Purpose | Workflow |
|---|---|---|
| SonarQube Cloud (SonarCloud) | Static code analysis, code smells, security hotspots, test coverage, quality gates. | `.github/workflows/sonar.yml` |
| SenseTheLog | AI-powered root cause analysis, suggested fixes, and recurring-failure pattern detection when a workflow fails. | Analysis step in `sonar.yml` and analysis job in `ci.yml` |

### SonarCloud Setup

1. Sign in at [sonarcloud.io](https://sonarcloud.io/) and create an organization and a project for this repository.
2. Generate a token under **My Account → Security**.
3. In GitHub, go to **Settings → Secrets and variables → Actions → New repository secret**:
   - **Name:** `SONAR_TOKEN`
   - **Value:** your SonarCloud token
4. Fill in your identifiers in `sonar-project.properties`:

```properties
sonar.organization=your-sonarcloud-organization-key
sonar.projectKey=your-sonarcloud-project-key
sonar.host.url=https://sonarcloud.io
```

The token lives only in the GitHub Actions secret named `SONAR_TOKEN`. It is never committed to the repository, never passed through `sonar-project.properties`, and GitHub Actions automatically masks it in logs. `SONAR_HOST_URL` is hardcoded to `https://sonarcloud.io` in the workflow.

While the placeholders above are unfilled, the workflow runs tests, coverage, and lint as usual but skips the SonarCloud scan and quality gate with a warning — the pipeline will not fail just because the project has not been imported into SonarCloud yet.

**Running analysis:** The `SonarCloud` workflow runs automatically on every push to `main`, every pull request, and on demand via `workflow_dispatch`. It installs dependencies, runs unit tests with coverage (`npm run test:coverage`, c8 wrapping the existing `node:test` suite), runs lint, then scans with the official `SonarSource/sonarqube-scan-action` and enforces the quality gate via `SonarSource/sonarqube-quality-gate-action`. Results appear in the SonarCloud dashboard and as a check on each commit/PR.

**Coverage:** `coverage/lcov.info` is produced by the `test:coverage` script and picked up automatically by `sonar-project.properties`. Coverage is optional for the scan; the workflow still runs if no coverage is produced.

### SenseTheLog Setup

[SenseTheLog](https://sensethelog.com/) analyzes failed GitHub Actions runs with AI: root cause analysis, suggested fixes posted as PR comments, and recurring-failure pattern detection. The integration uses the official [`sensethelog/action`](https://github.com/sensethelog/action) GitHub Action.

1. Sign up at sensethelog.com and create an API key in Settings.
2. Configure the repository secret **Settings → Secrets and variables → Actions** (already done for this repository — verify it is named exactly `SENSETHELOG_API_KEY`).

The analysis runs only after a workflow failure and never blocks or changes the pipeline outcome (`continue-on-error: true`). Suggested fixes are advisory only: the action's `make-fix` input stays `false`, so it never modifies source code, commits, pushes, or merges. Only the API key is sent to the service (via your secret); no application secrets, OAuth tokens, or judging data are involved, because SenseTheLog only reads failed workflow logs through the GitHub API.

### Required GitHub Secrets Summary

| Secret | Used by | Status |
|---|---|---|
| `SONAR_TOKEN` | SonarCloud scan and quality gate | Requires setup |
| `SENSETHELOG_API_KEY` | AI failure analysis | Configured — if analysis jobs are skipped, verify the exact secret name |

### Monitoring Analysis Troubleshooting

- **SonarCloud workflow green but no Scans tab entries, with a "placeholder" warning:** `sonar.organization` and `sonar.projectKey` in `sonar-project.properties` are still placeholders. Analysis, quality gate, and PR decoration stay disabled until they are replaced with your real values — the workflow will not fail.
- **SonarCloud scan fails with "Failed to fetch project" / 401:** `sonar.organization`/`sonar.projectKey` do not match your SonarCloud project, or the `SONAR_TOKEN` secret is missing, expired, or lacks access to it. For a brand-new fix, also confirm the project exists on sonarcloud.io (import it once, then re-run).
- **Quality gate always red — "coverage not met":** open the SonarCloud dashboard, check which files are uncovered, and add tests under `tests/`. Coverage currently comes only from the `tests/scoring.test.js` suite.
- **SenseTheLog analysis job is skipped:** either the workflow did not fail (it runs only on failure) or the `SENSETHELOG_API_KEY` secret name does not match exactly. Check **Settings → Secrets and variables → Actions**.
- **SenseTheLog analysis fails:** it never affects pipeline success (`continue-on-error`). Check that the free-tier quota (100 analyses/month) is not exhausted and that the key is valid in the SenseTheLog dashboard.

## Security & Data Integrity

Security is an important part of HackJudge's architecture.

- Supabase Row Level Security (RLS) policies restrict database access.
- Organizer and judge permissions are enforced through database policies.
- Judge assignments are associated with verified email identities.
- Database access is designed around competition ownership and judge assignments.
- Privileged backend credentials must remain server-side.

## Project Structure

```text
HackJudge/
│
├── .github/
│   └── workflows/
│
├── public/
│
├── src/
│
├── supabase/
│   └── migrations/
│
├── tests/
│
├── HACKJUDGE_CORE_SCHEMA.sql
├── HackJudge_Project_Report.pdf
├── REMEDIATION_LOG.md
├── Dockerfile
├── .dockerignore
├── .gitignore
├── eslint.config.js
├── index.html
├── package.json
├── vite.config.js
├── vercel.json
└── README.md
```

## Contributing

Contributions, bug reports, feature suggestions, and improvements are welcome.

If you find an issue or have an idea to improve HackJudge:

1. Open an issue describing the problem or suggestion.
2. Fork the repository.
3. Create a feature branch.
4. Submit a pull request.

Visit the [Issues](https://github.com/GURUBAKSHYADAV-71218/HackJudge/issues) page to report bugs or suggest improvements.

---

**Built with precision. Designed for scale.**

Making competition evaluation smarter, faster, and more transparent.
