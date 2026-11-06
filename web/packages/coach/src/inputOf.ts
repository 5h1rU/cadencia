/** A command's input without its tag, to copy into an event. */
export const inputOf = <A extends { readonly _tag: string }>(command: A): Omit<A, "_tag"> => {
  const { _tag: _, ...input } = command;
  return input;
};
