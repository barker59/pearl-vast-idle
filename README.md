# pearl-vast-idle

Pearl (SRBMiner pearlhash) as an official Vast default job on hosted machines, with
per-card tuning applied only to GPUs running the job. Renters' GPUs are left alone.

| Vast machine | Host | GPUs | Job price | Worker |
|---|---|---|---|---|
| 107877 | aaron-MZ73-LM0-000 | 2x RTX PRO 6000 WS | $0.74/GPU | EPYC-defaultjob |
| 154125 | asrackturin4u10g | 5x RTX 5080 | $0.14/GPU | Asrack-defaultjob |
| 137747 | c-mini | 2x RTX 5080 | $0.15/GPU | cmini-defaultjob |

The image holds only the miner; the wallet and pool are passed as job args. It is built
by `.github/workflows/build-image.yml` and published to `ghcr.io/barker59/pearl-srb`.

Do not commit passwords, tokens or API keys here.
