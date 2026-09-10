# Health4AI web — performance-preserving UI contract

Scope: website performance pass (2026-09-10), not a redesign or iOS specification.

## Existing visual system

Use the existing layout/CSS tokens (`--accent`, `--accent-light`, `--muted`,
`--border`) and current Tailwind typography, spacing and responsive breakpoints.
This pass changes no color, font, radius or content token. Do not substitute a
different venture's design system. Existing layout is the visual baseline.

## Brand image pattern

`BrandLogo.astro` uses Astro's build-time image pipeline and the existing
`public/logo.png` source. Generate WebP widths 32, 64 and 96; do not commit
generated assets. Declare the rendered size explicitly and preserve existing
classes, clipping and alternate text.

- Navigation and blog brand marks retain the 32px square box.
- The homepage footer retains the decorative 20px mark and empty alternate text.
- Logo optimization must not move adjacent text, links or form controls.

## Motion and critical content

- Homepage heading, explanation, metric pills and waitlist form are visible
  immediately. Do not reintroduce staggered fade-in entrance classes.
- Decorative ECG, floating cards, ring, peak and CTA effects retain their current
  appearance for visitors who have not requested reduced motion.
- Under `prefers-reduced-motion: reduce`, disable those decorative animations,
  including pulsing dots. Set ECG stroke offset to zero so the line remains
  visible; disabling the animation must not erase the diagram.
- Shared homepage styles remain on the homepage because HomeHero and HomeDetails
  are static component extractions, not new hydrated islands.

## Preserve behavior and meaning

Keep copy, disclaimers, links, tab behavior, analytics hooks and waitlist scripts
unchanged. Both waitlists retain unchecked, explicit Apple/TestFlight consent,
email → consent → submit order, and duplicate-signup messaging. No real signup
may be created during verification; intercept the request in tests.

## Verification

Normal builds run emitted-output performance and mocked-form tests. Review the
375px and 1440px renders for preserved hierarchy, wrapping, logo fidelity and
control visibility. Browser-check the actual form and tabs separately from the
source comparison. Independent code review and Sasha's rendered gate are required
before merge. Publication requires separate approval.

Apply the canonical [AI-tells rubric](/Users/jgl/claude-agents/docs/operations/ai-tells-rubric.md)
to the rendered change; this focused contract is not a full site design audit.
