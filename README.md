# CONNECTD Event Tracker

Event tracker for CONNECTD X 2026: partnership sales, P&L, programme, participant profile, marketing and operations, plus a public sales view (with ROI calculator) and a contractor booth-layout view.

- **Hosting:** GitHub Pages (`index.html`, no build step)
- **Data and sign-in:** Supabase (email sign-in link, no passwords)

## Views

| Link | Who | Shows |
|---|---|---|
| `/` | Editors | Full team tracker |
| `/#sales` (`#sales-roi`, `#sales-booths`, …) | Anyone who signs in | Packages, ROI calculator, booths, audience, programme |
| `/#contractor` | Anyone who signs in | Hall 6 booth layout only |

Editors are the emails in the `editors` table. Everyone else who signs in sees only the sales and contractor views, served from `public_tracker()`, which leaves out deal values, payments, salespeople, notes and the P&L.

## Setup

1. Create a Supabase project and run `supabase/schema.sql` in the SQL Editor.
2. Add editor emails: `insert into public.editors (email) values ('name@example.com');`
3. In Supabase **Authentication → URL Configuration**, set the Site URL to the GitHub Pages address.
4. Put the project URL and anon key in `index.html` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). The anon key is meant to be public; access is enforced by the database rules.
