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
