/**
 * @supademo/shared — the domain layer every frontend imports.
 *
 * Nothing in here touches the DOM, React, or Node built-ins, so the same code
 * runs in a browser, in React Native, in an Electron main process and in a CLI.
 */

export * from "./client.ts";
export * from "./permissions.ts";
export * from "./schemas.ts";
export * from "./types.ts";
export * from "./rpc.ts";
