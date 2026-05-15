/**
 * Minimal Deno global type shim for VS Code's standard TypeScript language server.
 *
 * This file is NOT needed at runtime — Deno provides these types natively.
 * It exists only so that editors without the Deno VS Code extension can
 * resolve `Deno.serve` and `Deno.env` without errors.
 *
 * If you install the "denoland.vscode-deno" extension and enable it via
 * .vscode/settings.json, this file becomes a no-op (Deno LSP takes over).
 */
declare namespace Deno {
  const env: {
    get(key: string): string | undefined;
    set(key: string, value: string): void;
    delete(key: string): void;
    toObject(): { [key: string]: string };
  };

  function serve(
    handler: (request: Request) => Response | Promise<Response>,
    options?: {
      port?: number;
      hostname?: string;
      onListen?: (params: { port: number; hostname: string }) => void;
    }
  ): void;
}
