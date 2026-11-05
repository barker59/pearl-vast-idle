# pearl-vast-idle

Pearl (SRBMiner pearlhash) as an official Vast default job on hosted machines, with
per-card tuning applied only to GPUs running the job. Renters' GPUs are left alone.

| Vast machine | Host | GPUs | Job price | Worker |
|---|---|---|---|---|
| 107877 | aaron-MZ73-LM0-000 | 2x RTX PRO 6000 WS | $0.74/GPU | EPYC-defaultjob |
| 154125 | asrackturin4u10g | 5x RTX 5080 | $0.18/GPU | Asrack-defaultjob |
| 137747 | c-mini | 2x RTX 5080 | $0.16/GPU | cmini-defaultjob |

The image holds only the miner; the wallet and pool are passed as job args. It is built
by `.github/workflows/build-image.yml` and published to `ghcr.io/barker59/pearl-srb`.

Do not commit passwords, tokens or API keys here.

## Starting a job

Always run `vastai start instance <id>` on a queued instance of that machine after every
`vastai set defjob`. Without it the instances can stay queued for 13+ minutes. With it the job
started on every free GPU within 20-40 seconds, even when the reply says the state change is
queued. Find the ids with `vastai show instances`.

## One job instance per card

Vast makes one job instance per GPU, and each instance stays bound to the card it first starts on.
So send a job only when every card on the machine is free. Sent while a renter holds cards, the
extra instances bind to whichever card is free later, which leaves several on one card and none on
the rented cards. Those cards then stay idle after the renter leaves, and the instances sharing a
card swap with each other.

Check the binding on the host, where each card should appear once:

```
grep "assign_and_update_used_gpus() elap" /var/lib/vastai_kaalia/kaalia.log | tail -1
```

If a card is missing, wait until all cards are free and re-send the job at the same price. Re-sending
restarts the job on every card and leaves renters alone.
