# codhoot-dotnet-service

Execution server for CodHoot's **.NET** languages — C#, F# and PowerShell. All
three sit on the same runtime stack, so they share one service.

## Why this service exists

CodHoot's single-language services each hard-code one compiler and one entry
filename, so they cannot be reused for a language they were not built for. The
backend routes these languages here through the shared runtime image URL:

```
COMPILER_IMAGE_DOTNET_SERVICE_URL=https://codhoot-dotnet-service-<suffix>.onrender.com
```

One variable covers all three languages. The mapping is read at backend startup,
so set the variable and restart the backend service.

## Contract

`POST /compile`, signed with
`HMAC-SHA256(secret, timestamp + path + hex(sha256(body)))` keyed by
`CODHOOT_INTERNAL_SECRET`, headers `X-CodHoot-Timestamp` (unix seconds) and
`X-CodHoot-Signature` (hex digest). Unsigned, tampered or stale requests get
401.

```json
{ "language": "csharp", "source": "class P { static void Main() { System.Console.WriteLine(\"hi\"); } }" }
```

`GET /health` and `GET /health/live` are open — Render's health check and the
keepalive pinger must never need a signature.

| language    | entry file | compile                                                      | run              |
|-------------|------------|--------------------------------------------------------------|------------------|
| csharp      | `main.cs`  | `mcs -out:main.exe {src}`                                     | `mono main.exe`  |
| fsharp      | `main.fs`  | `mono /opt/toolchains/fsharp/tools/fsc.exe {src} -o main.exe` | `mono main.exe`  |
| powershell  | `main.ps1` | —                                                            | `pwsh -NoLogo -NoProfile -NonInteractive -File {src}` |

Those command lines are the backend registry's own `CompileCommand` and
`RunCommand` for each language, so a job behaves identically to the local
`codhoot-runner-dotnet` docker path. PowerShell is in this family rather than
in the scripting service because it is a .NET application, not a Debian
interpreter package.

## Toolchains

- **C#** — mono's `mcs`, from Debian bookworm; the produced `.exe` runs on the
  mono runtime.
- **F#** — the F# compiler from the `FSharp.Compiler.Tools` 10.2.3 NuGet
  package, executed by the same mono runtime. Debian dropped its own `fsharp`
  package after squeeze, so the compiler comes from the versioned artifact
  instead of from apt.
- **PowerShell** — the upstream 7.4.6 self-contained release tarball.

All three are smoke-tested during the image build: a runtime the image cannot
execute is worse than a failed build.

## Deployment

Render blueprint: **New → Blueprint**, point it at this repo, apply. Set
`CODHOOT_INTERNAL_SECRET` to the same value the backend uses.

The service listens on `PORT` (Render sets it to 10000; the image default is
8081). `MAX_CONCURRENT_JOBS` defaults to 2.

## Sandbox

Each job gets its own uid from a 32-entry pool, a private random 0700 working
directory, a minimal environment, rlimits applied by a trampoline re-exec, and
process-group kill on timeout. The service runs as root only to chown and
setuid; the boundary is the child. See `harden.go` / `harden_unix.go`.