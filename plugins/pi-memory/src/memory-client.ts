// Thin REST client for the long-term memory backend (graphrag-server).
// Talks to the memory REST API on port 17180.
// ---------------------------------------------------------------------------

import { BASE_URL } from "./config";

export async function memoryRequest(
  method: string,
  path: string,
  body?: object,
): Promise<any> {
  const url = `${BASE_URL}${path}`;
  const res = await fetch(url, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(
      `memory ${method} ${path} failed (${res.status}): ${text}`,
    );
  }
  return res.json();
}
