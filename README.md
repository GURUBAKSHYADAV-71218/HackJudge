<div align="center">
  <img src="./public/favicon.svg" alt="HackJudge Logo" width="120" height="120" />
  <h1>HackJudge</h1>
  <p><strong>The High-Performance Evaluation Engine for Hackathons & Pitch Competitions</strong></p>
  <p>
    <a href="https://hack-judge-v2.vercel.app/">Live Demo</a> ·
    <a href="#features">Features</a> ·
    <a href="#tech-stack">Tech Stack</a> ·
    <a href="#getting-started">Getting Started</a>
  </p>
</div>

<hr />

HackJudge is a premium, high-contrast judging platform designed to replace the friction of spreadsheets with a seamless, digital evaluation experience. Whether you're running a high-stakes hackathon, a startup pitch competition, or an academic case study, HackJudge gives organisers total control and judges a frictionless scoring experience.

## Features

- **Frictionless UI/UX**: Ultra-fast, dual-theme (Light/Dark) interface with smooth micro-animations.
- **Judge Account Claiming**: Judges use verified Supabase Auth accounts matched to the email assigned by an organizer. Magic-link invites are currently paused.
- **Dynamic Round Builder**: Create customized scoring criteria with weighted averages mapped to specific rounds.
- **Intelligent Panel Management**: Assign specific tracks and teams to targeted judging panels.
- **Scoring and Results**: Organizer dashboards calculate results from completed judge submissions.
- **Database Access Controls**: Supabase Row Level Security policies restrict access by organizer and judge assignment.
- **Bulk Data Handling**: Drag-and-drop CSV uploads to import hundreds of teams in seconds.

## Tech Stack

- **Frontend**: React 19, Vite, CSS (Vanilla + CSS Variables for theming)
- **State Management**: React Query (`@tanstack/react-query`)
- **Backend & Auth**: Supabase (PostgreSQL and GoTrue Auth; judge invite Edge Function deferred)
- **Icons**: Lucide React
- **Deployment**: Optimized for Vercel

## Getting Started

### Prerequisites

Ensure you have [Node.js](https://nodejs.org/) installed, and a [Supabase](https://supabase.com/) project set up.

### 1. Clone the repository

```bash
git clone https://github.com/YOUR_USERNAME/hackjudge.git
cd hackjudge
```

### 2. Install dependencies

```bash
npm install
```

### 3. Setup Environment Variables

From the repository root, copy the example environment file and fill in your Supabase project URL and public anon/publishable key:

```powershell
Copy-Item .env.example .env
```
Inside `.env`:
```env
VITE_SUPABASE_URL=https://your-project-id.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-public-key
```

### 4. Database Schema Setup

For a new, empty Supabase project using the core email-account judge flow, run `HACKJUDGE_CORE_SCHEMA.sql` once in the Supabase SQL Editor. Do not run it against an existing project. Existing-project upgrades use the ordered migrations in `supabase/migrations/` and require a separate reviewed rehearsal. Follow [DEPLOYMENT_RUNBOOK.md](./DEPLOYMENT_RUNBOOK.md) for the deployment steps.

Organizers and judges authenticate with Google. Configure the Google OAuth provider in Supabase and the matching Web OAuth client in Google Cloud. Organizers add judges by email; a judge must sign in with Google using that same email, and the app claims the assignment automatically. Judge magic-link invites are paused.

### 5. Run the Development Server

```bash
npm run dev
```

The app will be available at `http://localhost:5173`.

## Deployment

HackJudge is pre-configured for Vercel. 
1. Push your code to GitHub.
2. Import the repository in Vercel.
3. Add the `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` to the Vercel Environment Variables.
4. Deploy! The included `vercel.json` will automatically handle SPA routing.

The core account flow does not require the `resolve-judge-token` Edge Function. Judge invite links are paused while the platform uses regular, verified Supabase Auth accounts.

## Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the [issues page](https://github.com/YOUR_USERNAME/hackjudge/issues).

---

<div align="center">
  Built with precision. Designed for scale.
</div>
