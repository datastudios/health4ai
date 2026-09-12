# health4ai — Sasha UX Brief
**Requester:** Jeff / JGLV  
**Project:** health4ai (health4.ai — Astro on CF Pages, existing site)  
**Sasha gate:** required before merge, per policy  

---

## Work items (3 discrete changes)

---

### 1. Blog section — /blog

Add a blog content collection to the existing Astro site.

**Spec:**
- Create `src/content/blog/` directory with schema (`src/content/config.ts`)
- Schema fields: `title` (string), `description` (string), `pubDate` (date), `slug` (string), `tags` (string[]), `draft` (boolean, default false)
- Create `src/pages/blog/index.astro` — article list page, filtered to `draft: false` and `pubDate <= today`
- Create `src/pages/blog/[slug].astro` — article detail page
- Add "Blog" to the nav (between "Compare" and the GitHub icon)
- Style: match existing site aesthetic (dark bg, accent `#ff2d78`, same card/typography patterns as rest of site)
- Card layout on index: title, description, date, estimated read time (word count ÷ 200)
- Article page: no sidebar, clean reading width (~680px), code blocks styled with existing `.code-block` class

**Routing:**
- `/blog` → index
- `/blog/[slug]` → article
- Each article in `src/content/blog/YYYY-MM-DD-slug.md`

**SEO per article:**
- `<title>`: article title + " — health4ai"
- `<meta name="description">`: article description field
- `<link rel="canonical">`: `https://health4.ai/blog/[slug]`
- Open Graph tags (title, description, type=article, pubDate)

---

### 2. Founding batch banner

A subtle, dismissible banner that appears above the nav on the landing page only.

**Spec:**
- Position: above nav (not floating, part of document flow)
- Copy: `health4ai is free through July. Founding batch gets lifetime access.` + a `→` that links to `#founding-batch` anchor on the landing page
- Style: dark background (slightly lighter than page bg), accent pink text for the CTA arrow, no aggressive coloring
- Dismissible: clicking an `×` sets `localStorage.setItem('h4ai_banner_dismissed', '1')` and hides the banner. On revisit, banner stays hidden.
- The end date text should be dynamically loaded from Supabase `health4ai_config` table, key `founding_batch_end_date`. Fetch via Supabase anon key (already in `PUBLIC_SUPABASE_URL` + `PUBLIC_SUPABASE_ANON_KEY` env). Graceful fallback to "July 31" if fetch fails.
- Do NOT show the banner after August 1, 2026 (check against today's date, suppress entirely)

---

### 3. FAQ schema markup (landing page)

Add JSON-LD structured data to the landing page `<head>` for these FAQ items:

```json
{
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": [
    {
      "@type": "Question",
      "name": "What is the best way to get Apple Health data into Claude Code?",
      "acceptedAnswer": {
        "@type": "Answer",
        "text": "health4ai is an open-source iOS app and MCP server that syncs HealthKit data to your Postgres database and exposes it to Claude Code, Cursor, and Ollama as native tool calls. It uses HKObserverQuery for reliable background sync and syncs to a Supabase project you own."
      }
    },
    {
      "@type": "Question",
      "name": "Does Claude's native Apple Health integration work with Claude Code?",
      "acceptedAnswer": {
        "@type": "Answer",
        "text": "No. Anthropic's Apple Health connector is a claude.ai web feature only. It doesn't reach Claude Code, the API, n8n, or any MCP client outside the browser. health4ai closes this gap with a self-hosted MCP server."
      }
    },
    {
      "@type": "Question",
      "name": "What databases does health4ai support?",
      "acceptedAnswer": {
        "@type": "Answer",
        "text": "A Supabase project you own. The iOS app signs in with Supabase Auth and writes through a Supabase Edge Function, so plain Postgres such as Neon or a self-hosted database is not supported. Supabase's free tier covers personal use."
      }
    },
    {
      "@type": "Question",
      "name": "Is health4ai open source?",
      "acceptedAnswer": {
        "@type": "Answer",
        "text": "Yes. The iOS app and MCP server are both open source on GitHub at github.com/jefflitt1/health4ai."
      }
    },
    {
      "@type": "Question",
      "name": "Does health4ai store my health data?",
      "acceptedAnswer": {
        "@type": "Answer",
        "text": "No. Your health data syncs directly to your own database. health4ai never stores, transmits, or has access to your health data."
      }
    },
    {
      "@type": "Question",
      "name": "What Apple Health metrics does health4ai sync?",
      "acceptedAnswer": {
        "@type": "Answer",
        "text": "health4ai syncs all major HealthKit metrics: steps, heart rate, HRV, sleep stages, workouts, weight, VO2 max, blood oxygen, body temperature, blood pressure, respiratory rate, blood glucose, and all dietary nutrition data."
      }
    }
  ]
}
```

Place in `<head>` of `src/pages/index.astro` as a `<script type="application/ld+json">` tag.

---

## Acceptance criteria
- `/blog` renders without error, articles filterable by date
- `/blog/[slug]` renders an article with correct title/description meta tags
- Nav shows "Blog" between "Compare" and GitHub
- Banner appears on index, dismisses on `×` click, respects localStorage
- Banner suppresses after Aug 1
- FAQ JSON-LD validates at https://validator.schema.org/
- Mobile: banner and blog pages responsive at 375px
