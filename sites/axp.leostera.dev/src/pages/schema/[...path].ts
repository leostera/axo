import type { APIRoute, GetStaticPaths } from "astro";
import { schemas } from "../../lib/site";

// Every schema at the URL its `$id` names.
export const getStaticPaths: GetStaticPaths = () =>
  schemas().map((schema) => ({ params: { path: schema.path.replace(/^\/schema\//, "") }, props: { text: schema.text } }));

export const GET: APIRoute = ({ props }) =>
  new Response(props.text as string, { headers: { "content-type": "application/schema+json; charset=utf-8" } });
