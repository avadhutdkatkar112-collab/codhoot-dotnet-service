FROM golang:1.22-bookworm@sha256:1f298b0c9fecdf504389a0329236f948cc04a566a2bb32337207cbaaa2f8177c AS builder
WORKDIR /build
# Copy every Go source file, not just main.go: the sandbox hardening lives in
# harden.go (portable) plus harden_unix.go / harden_other.go (per-platform).
COPY go.mod ./
COPY main.go harden.go harden_unix.go harden_other.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/service .

# C#, F# and PowerShell: one image, three languages, because all three sit on
# the same runtime stack.
#
#   * C#        -> mono's mcs compiler (mono-mcs), which is in Debian bookworm,
#                  and the produced .exe is executed by the mono runtime.
#   * F#        -> the F# compiler from the FSharp.Compiler.Tools package, run by
#                  the same mono runtime. Debian dropped its own `fsharp`
#                  package after squeeze, so the compiler comes from the
#                  versioned NuGet artifact instead of from apt.
#   * PowerShell-> the upstream self-contained release tarball. It is a .NET
#                  application, so it belongs to this family rather than to the
#                  scripting service, whose interpreters are all Debian
#                  packages.
FROM gcc:13.2-bookworm
LABEL org.opencontainers.image.title="codhoot-dotnet-service"
LABEL org.opencontainers.image.description="Hardened .NET execution sandbox (csharp, fsharp, powershell)"

ARG FSHARP_TOOLS_VERSION=10.2.3
ARG POWERSHELL_VERSION=7.4.6

RUN set -eux; \
    apt-get update; \
    # --reinstall, not a plain install: the base image deletes the curl binary
    # for security while leaving dpkg's record intact, so a plain install
    # reports "already the newest version" and leaves the binary missing.
    apt-get install -y --no-install-recommends --reinstall curl unzip ca-certificates; \
    apt-get install -y --no-install-recommends mono-mcs mono-runtime mono-devel; \
    mkdir -p /opt/toolchains/fsharp /opt/toolchains/powershell; \
    curl -fsSL -o /tmp/fsharp.nupkg \
      "https://www.nuget.org/api/v2/package/FSharp.Compiler.Tools/${FSHARP_TOOLS_VERSION}"; \
    unzip -q -o /tmp/fsharp.nupkg -d /opt/toolchains/fsharp; \
    rm -f /tmp/fsharp.nupkg; \
    curl -fsSL -o /tmp/powershell.tar.gz \
      "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-x64.tar.gz"; \
    tar -xzf /tmp/powershell.tar.gz -C /opt/toolchains/powershell; \
    rm -f /tmp/powershell.tar.gz; \
    # Fetch tooling has done its job; the shipped image carries none, matching
    # every other CodHoot sandbox.
    apt-get purge -y --auto-remove curl unzip; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    ln -sf /opt/toolchains/powershell/pwsh /usr/local/bin/pwsh; \
    chmod +x /opt/toolchains/powershell/pwsh

# Smoke test each toolchain at build time: a runtime the image cannot execute is
# worse than a failed build, and these three come from outside Debian's archive.
RUN set -eux; \
    echo 'class Smoke { static void Main() { System.Console.WriteLine("csharp ok"); } }' > /tmp/smoke.cs; \
    mcs -out:/tmp/smoke.exe /tmp/smoke.cs; \
    mono /tmp/smoke.exe; \
    echo 'printfn "fsharp ok"' > /tmp/smoke.fs; \
    mono /opt/toolchains/fsharp/tools/fsc.exe /tmp/smoke.fs -o /tmp/smoke-fs.exe; \
    mono /tmp/smoke-fs.exe; \
    pwsh -NoLogo -NoProfile -Command 'Write-Output "powershell ok"'; \
    rm -f /tmp/smoke.cs /tmp/smoke.exe /tmp/smoke.fs /tmp/smoke-fs.exe

WORKDIR /app
COPY --from=builder /out/service /app/service
RUN chmod 0755 /app/service && rm -f go.mod main.go harden.go harden_unix.go harden_other.go

# --- sandbox identity pool ---------------------------------------------------
# Each in-flight job is dropped to a DISTINCT uid by the service. That is what
# makes a job's 0700 working directory genuinely private: with one shared uid every
# job could read every other job's source and rewrite it before it ran.
# Runtimes that resolve getpwuid need real passwd entries, written directly here
# rather than with 32 useradd calls.
# shellcheck disable=SC2016
RUN set -eu; \
    i=0; \
    while [ "$i" -lt 32 ]; do \
      u=$((2000 + i)); \
      printf 'codhoot-s%d:x:%d:%d:codhoot sandbox:/nonexistent:/sbin/nologin\n' "$i" "$u" "$u" >> /tmp/pool; \
      i=$((i + 1)); \
    done; \
    cat /tmp/pool >> /etc/passwd; \
    rm -f /tmp/pool; \
    mkdir -p /tmp/codhoot-cache; \
    chmod 0755 /tmp/codhoot-cache

# The service itself runs as root on purpose: it must chown each job directory to
# that job's uid and setuid the compiler/runtime child. The security boundary is
# the child, not the service.
#
# There is deliberately no HEALTHCHECK here: it would require curl or wget in the
# image, and Render already health-checks /health over HTTP.
ENV PORT=8081
EXPOSE 8081
CMD ["/app/service"]