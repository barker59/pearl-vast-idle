# pearl-vast-idle

Pearl (SRBMiner pearlhash) as an official Vast default job on hosted machines, with
per-card tuning applied only to GPUs running the job. Renters' GPUs are left alone.

| Vast machine | Host | GPUs | Job price | Worker |
|---|---|---|---|---|
| 107877 | aaron-MZ73-LM0-000 | 2x RTX PRO 6000 WS | $0.7401/GPU | EPYC-defaultjob |
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

## Testing an image outside Vast

Always run a test container with `--rm --log-opt max-size=20m --log-opt max-file=1`. On 2026-11-11 a
3.8.6 test container without a log limit wrote a 5.9 TB log on 154125, which filled Docker's storage
and stopped the default job on three cards. Remove test containers when the test ends.

## Job price

Vast stores the job price divided by 0.75 and compares it with the min bid rounded to 7 decimals.
Some prices fall just below that rounded value, and Vast then stops the job within minutes even on
a free card. At $0.74 the bid is 0.98666666... against a minimum of 0.9866667. Check any new price
with `vastai show instance <id> --raw`: `dph_total` must not be below `min_bid`, and a job Vast
wants stopped shows `intended_status` stopped while still running. $0.16 and $0.18 are safe when
they equal the min bid; $0.14, $0.15, $0.17, $0.20, $0.73 and $0.74 are not. 107877 uses $0.7401
over its $0.74 min bid for this reason.

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
