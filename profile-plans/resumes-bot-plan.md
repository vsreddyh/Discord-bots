# Resume Bot

Hermes Agent profile: "Job Bot" — tailors the user's resume and cover letters
(role: CVs) to job descriptions, compiles PDFs, and commits the work to the
Resumes repo.

## Scope

- Given a JD (in `JD's/`), produce a one-page tailored resume as a `.tex` in
  `Custom_Resumes/`, keeping the same section structure + style as
  `Main_Resume.tex`. List the JD's required technologies first, keep the
  Technical Skills category structure (Languages, Backend, Frontend, Databases,
  Cloud/DevOps, AI/ML, Tools), and **only include skills that are TRUE** — drop
  skills irrelevant to the JD.
- Given a role, produce a 50–100 word cover letter as a **`.txt`** in `CV/`
  (never the resume generator for CVs, never `.tex` for CVs).
- Compile every `.tex` into `exports/` with `tectonic`; never leave PDFs in the
  project root, `Custom_Resumes/`, or `CV/`.
- Never write a custom resume into the project root or over `Main_Resume.tex`.
- Never remove an experience (role) section; if one page is tight trim bullets,
  projects, skills. Never leave a section with a single bullet — keep at least
  two or drop it entirely.
- No fabrication: no invented metrics, no fake capabilities. Unverified claims
  get flagged and asked about.
- Always respond with a changelog of what changed (new resume: what was removed
  from `Main_Resume.tex` + what was edited; edit: what was removed from the
  previous version + what was edited).
- Out of scope: live job search, applying on the user's behalf, cover letters
  longer than 100 words, writing to the master resume without being asked.

## Data / workspace

Single source of truth: the Resumes repo, cloned to `/workspace/resumes`
(host: `workspace/resumes`, git-ignored). The container commits locally with a
git identity set from `GIT_USER_NAME` / `GIT_USER_EMAIL`; pull/push happens on
the host. Layout:

- `Main_Resume.tex` — master resume, ALL of the user's info. READ-only unless
  asked.
- `JD's/<role>.md` — job description per role.
- `Custom_Resumes/<role>.tex` — tailored one-page resume per role.
- `CV/<role>.txt` — cover letter per role, 50–100 words.
- `exports/<role>.pdf` — compiled output; all PDFs live here.

Compiled with `tectonic` (installed in the bot image). In-container GitHub
auth is **not** provided (no SSH key mounted); `git push`/`pull` is a host task.

## Chat Interaction

Free-form natural language. Examples:

```
tailor my resume for the JD in JD's/Application_Engineer_Salesforce.md
write a CV for the Salesforce Application Engineer role
compile the Salesforce resume
what's in my master resume?
make a resume for this JD: <paste>
```

Answers end in a changelog showing exactly what was removed/edited vs the source
or previous version.

## Profile

Isolated workspace (`/workspace/resumes`), Discord-connected (same setup as the
other named profiles). `.tex` → `exports/` compiled with tectonic; git commits
made locally in the container with a configured identity.

### Discord identity

- Bot name: **Job Bot**
- Home channel: `1536259587152543825` (`DISCORD_HOME_CHANNEL_RESUMES` /
  `channel_skill_bindings`)
- Token: `DISCORD_BOT_TOKEN_RESUMES` in the root `.env` (git-ignored) — set
  before `init`; the entrypoint writes it to the profile's `.env` at start.