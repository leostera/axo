import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";

// The site renders the documents in axp/, so the spec has one source of truth.
const docs = defineCollection({
  loader: glob({ pattern: ["SPEC.md", "extensions/*.md"], base: "../../axp" }),
});

export const collections = { docs };
