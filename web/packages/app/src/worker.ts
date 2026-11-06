interface Fetcher {
  fetch(request: Request): Promise<Response>;
}

const FORWARDED = ["/api", "/auth/", "/v1/"];

/**
 * The app's Worker: the client build, plus the API, sign-in and the HTTP API
 * for iOS forwarded to Cadencia over a service binding. One origin for all.
 */
export default {
  fetch(request: Request, env: { readonly ASSETS: Fetcher; readonly CADENCIA: Fetcher }) {
    const { pathname } = new URL(request.url);
    return FORWARDED.some((prefix) => pathname.startsWith(prefix))
      ? env.CADENCIA.fetch(request)
      : env.ASSETS.fetch(request);
  },
};
