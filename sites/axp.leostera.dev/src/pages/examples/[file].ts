import type { APIRoute, GetStaticPaths } from "astro";
import { examples } from "../../lib/site";

export const getStaticPaths: GetStaticPaths = () =>
  examples().map((example) => ({ params: { file: example.file }, props: { text: example.text } }));

export const GET: APIRoute = ({ props }) =>
  new Response(props.text as string, { headers: { "content-type": "application/jsonl; charset=utf-8" } });
