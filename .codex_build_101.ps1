$ErrorActionPreference = 'Stop'

& 'E:\AI_WIKI\scripts\flutter-build-guarded.ps1' `
  -ProjectPath 'E:\FluxStudio\PlanFlow' `
  -Project 'PlanFlow' `
  -Owner 'codex-planflow-briefing-fix' `
  -BuildArgs 'appbundle --release --no-pub' `
  -WaitTimeoutSeconds 600 *>> 'E:\FluxStudio\PlanFlow\build_release_101.log'

exit $LASTEXITCODE
