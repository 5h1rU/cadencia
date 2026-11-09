import { vi } from "@effect/vitest";

/**
 * Intervals.icu takes the request and never answers: the call ends only when
 * its signal is aborted, as a real `fetch` would. Returns the signal of every
 * request made, in order.
 */
export const neverAnswers = () => {
  const requests: Array<AbortSignal> = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(
    (_input, init) =>
      new Promise<Response>((_resolve, reject) => {
        const signal = init?.signal;
        if (!signal) return;
        requests.push(signal);
        signal.addEventListener("abort", () => reject(signal.reason));
      }),
  );
  return requests;
};
