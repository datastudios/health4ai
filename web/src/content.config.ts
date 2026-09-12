import { glob } from 'astro/loaders';
import { defineCollection, z } from 'astro:content';

const blog = defineCollection({
  loader: glob({
    base: './src/content/blog',
    pattern: '**/*.{md,mdx}',
  }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    pubDate: z.date(),
    slug: z.string(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
    // Posts written before the 2026-09-12 setup correction. Renders a notice that Neon, local Docker
    // and the REST / Webhook option are not supported. Explicit per post so new posts never inherit it.
    legacySetup: z.boolean().default(false),
  }),
});

export const collections = { blog };
