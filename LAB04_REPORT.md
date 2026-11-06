# Lab 04 report

Student: Tristan  
Repo: https://github.com/Tristan-Tenders/Assignment-lab4 (tag `v1`, branch `feature/v2`)  
Mission 4: Path B. The Path A workflow (`sdlc.yml`) is also in the repo, but I only ran the local pipeline.

## Mission 0: Baseline

```
$ du -sh node_modules
143M	node_modules
```

devDependencies (10): @babel/core, eslint, jest, nodemon, prettier, sass, ts-node, typescript, webpack, webpack-cli

## Mission 1: The crash

```
$ docker run --rm -v "$PWD":/app -w /app -p 4173:4173 node:16 node server.js
/app/server.js:22
const stationsSnapshot = structuredClone(stations);
                         ^

ReferenceError: structuredClone is not defined
    at Object.<anonymous> (/app/server.js:22:26)
    at Module._compile (node:internal/modules/cjs/loader:1198:14)
    at Object.Module._extensions..js (node:internal/modules/cjs/loader:1252:10)
    at Module.load (node:internal/modules/cjs/loader:1076:32)
    at Function.Module._load (node:internal/modules/cjs/loader:911:12)
    at Function.executeUserEntryPoint [as runMain] (node:internal/modules/run_main:81:12)
    at node:internal/main/run_main_module:22:47
```

```
$ docker run -d --name citybike-test -v "$PWD":/app -w /app -p 4173:4173 node:20 node server.js
$ docker logs citybike-test
CityBike service listening on http://0.0.0.0:4173 [env=development]
```

**A)** The commit itself was fine; the runtime was the difference. My laptop runs a much newer Node than the QA container, so I never hit the problem. Nothing in the repo, like an `engines` field or a pinned image, told the QA machine it needed Node 17+.

**B)** Package versions (`npm install` can resolve different versions than `npm ci` with the lockfile), files that only exist on my laptop such as the gitignored `dist/` folder, and the CPU type: my Mac is arm64, while most servers are x86.

**C)** Right after the build in CI. The image should be built from a pinned base like `node:20` and started once with a `/health` check. In this lab that check is the staging gate.

## Mission 2: Naive Dockerfile

| First build | Rebuild after 1-line change in public/ | Image size |
|---|---|---|
| 25.1 s | 41.4 s | 2.02 GB |

```
$ docker images citybike
IMAGE            ID             DISK USAGE   CONTENT SIZE   EXTRA
citybike:naive   2ece41c96cfb       2.02GB          483MB
```

**A)** The files a `COPY` takes in are part of its cache key. My CSS edit changed what `COPY . .` copied, so that layer counted as new. After that, nothing below it in the Dockerfile could use the cache either, and `npm ci` sits below it.

**B)** Comparing my images: even the cache-fixed one is 1.84 GB, while the Alpine multi-stage one is 194 MB, so most of the weight is the Debian-based `node:20` image itself. Next is the `node_modules` that `npm ci` installs with all ten devDependencies (about 150 MB). Last is the second copy of my laptop's `node_modules` and `.git` that `COPY . .` added, which is why naive is about 180 MB bigger than cache-fixed.

**C)** `.git`, `node_modules`, `dist`, the Dockerfile, `README.md`, `.gitignore` and `.env.example`.

## Mission 3: Cache fix and multi-stage

`npm ci --omit=dev` shortcut:
```
#8 [4/6] RUN npm ci --omit=dev
#10 0.339 BUILD ERROR: Necessary devDependencies missing. Run npm run build in the builder stage.
#10 ERROR: process "/bin/sh -c npm run build" did not complete successfully: exit code: 1
ERROR: failed to build: failed to solve: process "/bin/sh -c npm run build" did not complete successfully: exit code: 1
```

Multi-stage image:
```
$ docker run --rm citybike:v1 ls node_modules
ls: node_modules: No such file or directory

$ docker images citybike
IMAGE            ID             DISK USAGE   CONTENT SIZE   EXTRA
citybike:cache   29f2acac698f       1.84GB          453MB
citybike:naive   2ece41c96cfb       2.02GB          483MB
citybike:v1      1043c273753c        194MB           49MB
```

| Version | Image size | Rebuild after 1-line change |
|---|---|---|
| Naive | 2.02 GB | 41.4 s |
| Cache-fixed | 1.84 GB | 4.1 s |
| Multi-stage | 194 MB | 1.0 s |

**A)** With the new order, the only things above `npm ci` are the base image and the two package files. A CSS change touches neither, so the build log shows `npm ci` as `CACHED`, and only `COPY . .` and `npm run build` actually ran.

**B)** `server.js` only requires `node:http`, `node:fs` and `node:path`, so there's nothing to install for it. It reads files from `public/` and checks whether `dist/build-manifest.json` exists. TypeScript is only used to write that JSON file during `npm run build` in the first stage. The run stage just gets the finished file, which is all `/health` looks for.

**C)** Fewer packages means fewer vulnerabilities to patch, and there's no npm toolchain or compiler left for someone to misuse if they got into the container. It also runs as `node`, not root. For ops, pulling 49 MB instead of 483 MB makes deploys and rollbacks quicker, and the image fits the 220 MB limit that preprod checks.

## Mission 4: Five gates

My `scripts/pipeline.sh` starts each gate's container on port 4174, waits for `/health`, runs that gate's test script and then removes the container. If the first four pass, it deploys prod on port 4173. It stops at the first failure.

```
$ ./scripts/pipeline.sh citybike:v1

[pipeline] Promoting immutable image citybike:v1 (sha256:1043c273753c)

[pipeline] GATE 1/5 STAGING: starting citybike:v1 as citybike-gate on :4174
[STAGING] Verifying /health and build manifest...
Health payload: {"ok":true,"environment":"staging","hasBuildManifest":true,"secureKeyConfigured":false}
[STAGING] Verifying /api/stations contract...
[STAGING] PASSED.

[pipeline] GATE 1/5 STAGING: GREEN

[pipeline] GATE 2/5 UAT: starting citybike:v1 as citybike-gate on :4174
[UAT] Verifying UI static assets (/, /app.js, /styles.css)...
[UAT] Verifying 4 stations and Riverside Park at 0 bikes...
[UAT] Scenario 1: Valid reservation at Central Square (8 bikes)...
[UAT] Scenario 2: Reject reservation with invalid email format...
[UAT] Scenario 3: Reject reservation at zero-bike station (Riverside Park)...
[UAT] PASSED.

[pipeline] GATE 2/5 UAT: GREEN

[pipeline] GATE 3/5 OAT: starting citybike:v1 as citybike-gate on :4174
[OAT] Testing malformed JSON handling (expect HTTP 400)...
[OAT] Testing >10KB payload flood guard...
[OAT] Running 50-request burst load test...
[OAT] PASSED.

[pipeline] GATE 3/5 OAT: GREEN

[pipeline] GATE 4/5 PREPROD: starting citybike:v1 as citybike-gate on :4174
[PRE-PROD] Auditing Docker image size for citybike:v1...
[PRE-PROD] Verifying devDependencies (typescript) are excluded from runtime image...
[PRE-PROD] Verifying environment promotion flag (APP_ENV=preprod) and PROD_API_KEY...
[PRE-PROD] PASSED.

[pipeline] GATE 4/5 PREPROD: GREEN

[pipeline] GATE 5/5 PROD: deploying citybike:v1 as citybike-prod on :4173
[PROD] Running post-deployment production smoke & secret verification...
[PROD] Production verification PASSED.

[pipeline] GATE 5/5 PROD: GREEN

[pipeline] ALL FIVE GATES GREEN - citybike:v1 is live as citybike-prod on http://localhost:4173
```

**A)** A later gate only means something if the earlier ones passed. OAT firing 50 requests at an app that crashes on boot would just fail for the wrong reason. Having prod at the end of the chain also means a red result anywhere leaves prod unchanged.

**B)**

| Gate | What it checks that earlier gates don't |
|---|---|
| Staging | The container boots, `/health` reports the build manifest, and `/api/stations` has the expected shape |
| UAT | The UI files load, there are 4 stations, and booking returns 201 when valid and 422 for a bad email or an empty station |
| OAT | 400 on broken JSON, bodies over 10 KB rejected, and it survives 50 requests at once |
| Preprod | Image under 220 MB, no `typescript` inside, `APP_ENV=preprod`, and a real key injected |
| Prod | The live container reports `production` and has the real key |

**C)** The point of the gates is to prove things about one specific artifact. In my run every gate used the same image ID (`sha256:1043c273753c`). If each environment built its own image, a green staging run would say nothing about the prod image, because `node:20` or a package could have changed in between. There's also only one build to wait for, and rolling back is just starting an older tag.

**D)** `server.js` has a default: `process.env.PROD_API_KEY || 'DEV_LOCAL_INSECURE_KEY'`. Forgetting the secret doesn't break anything you can see; prod would just run with a key that's written in the source code. Staging, UAT and OAT never set the key, so they can't tell. The preprod test is the first one that looks at `secureKeyConfigured`, and the prod smoke test checks it again on the real deployment.

## Mission 5: Bad push vs. gate

v2 deployed straight to prod, without `DB_URL`:
```
$ docker ps -a --filter name=citybike
CONTAINER ID   IMAGE         COMMAND                  CREATED         STATUS                     PORTS     NAMES
c28e93651ba6   citybike:v2   "docker-entrypoint.s…"   3 seconds ago   Exited (1) 3 seconds ago             citybike-prod

$ curl -sS --max-time 5 http://localhost:4173/health
curl: (7) Failed to connect to localhost port 4173 after 0 ms: Couldn't connect to server

$ docker logs citybike-prod
node:internal/url:806
    const href = bindingUrl.parse(input, base, raiseException);
                            ^

TypeError: Invalid URL
    at new URL (node:internal/url:806:29)
    at Object.<anonymous> (/app/server.js:13:16)
    at Module._compile (node:internal/modules/cjs/loader:1521:14)
    at Module._extensions..js (node:internal/modules/cjs/loader:1623:10)
    at Module.load (node:internal/modules/cjs/loader:1266:32)
    at Module._load (node:internal/modules/cjs/loader:1091:12)
    at Function.executeUserEntryPoint [as runMain] (node:internal/modules/run_main:164:12)
    at node:internal/main/run_main_module:28:49 {
  code: 'ERR_INVALID_URL',
  input: 'undefined'
}

Node.js v20.20.2
```

**Decision: rollback.** This isn't a typo I could fix in a minute. v2 needs a `DB_URL` that prod doesn't have, so a fix means either changing the config or changing the code, and that new build would still have to go through the gates. v1 was already tagged and had passed all five gates, so restoring it took one command and added no new risk.

```
$ docker rm -f citybike-prod
citybike-prod
$ docker run -d --name citybike-prod -p 4173:4173 -e APP_ENV=production -e PROD_API_KEY=*** citybike:v1
dd48cbb1c1254c99852831440669f804fb10f54f3a8182c103e511990d85aba7
$ curl -sS http://localhost:4173/health
{"ok":true,"environment":"production","hasBuildManifest":true,"secureKeyConfigured":true}
```

Same v2 through the pipeline, from the `feature/v2` branch:
```
$ ./scripts/pipeline.sh citybike:v2

[pipeline] Promoting immutable image citybike:v2 (sha256:053a6eeb174f)

[pipeline] GATE 1/5 STAGING: starting citybike:v2 as citybike-gate on :4174

[pipeline] RED: container citybike-gate exited before becoming healthy. Logs:
node:internal/url:806
    const href = bindingUrl.parse(input, base, raiseException);
                            ^

TypeError: Invalid URL
    at new URL (node:internal/url:806:29)
    at Object.<anonymous> (/app/server.js:13:16)
    at Module._compile (node:internal/modules/cjs/loader:1521:14)
    at Module._extensions..js (node:internal/modules/cjs/loader:1623:10)
    at Module.load (node:internal/modules/cjs/loader:1266:32)
    at Module._load (node:internal/modules/cjs/loader:1091:12)
    at Function.executeUserEntryPoint [as runMain] (node:internal/modules/run_main:164:12)
    at node:internal/main/run_main_module:28:49 {
  code: 'ERR_INVALID_URL',
  input: 'undefined'
}

Node.js v20.20.2

[pipeline] RED: gate 1/5 STAGING failed (exit 1). Promotion stopped; later gates NOT run.

$ curl -sS http://localhost:4173/health
{"ok":true,"environment":"production","hasBuildManifest":true,"secureKeyConfigured":true}
```

## Mission 6: Wrap-up

```
$ git log --all --graph --oneline --decorate
* a94da74 (ogn/feature/v2, feature/v2) v2: log the db host
* e0cfab2 (HEAD -> main, ogn/main, ogn/HEAD) ci: five-gate promotion pipeline (pipeline.sh + sdlc.yml)
* 753f40a (tag: v1) Dockerfile: cache + multi-stage
* fe142f1 v1: station snapshot
* fa95935 docs; update README
* 10268b4 test: cover secure key configured
* 976fcd1 test: cover 4-station count check in UAT
* 22323aa ci: add uat testing
* bd8c0b4 refactor: update gitignore
* 540004f fix: switch module system to commonjs
* 1179a0f feat(public): add static files
* 6c56529 docs(readme): add lab instructions
* b912e96 initial commit
```

**What should happen when a gate is red?** That image is rejected for good, not patched and pushed on. The person who made the change gets the failing gate's output and fixes it in a new commit. That produces a new image, which has to start again from staging. Users don't notice any of it, because prod is still running whatever passed last.

**Why practise the rollback before you need it?** A rollback only helps if it works the first time. Practising checks things you'd otherwise just assume: that old images are kept and not cleaned up, that the env vars and secrets prod needs are written down somewhere, and that the old version still runs. When v2 broke prod here, it took me one `docker rm` and one `docker run`, because I already knew the exact command.
