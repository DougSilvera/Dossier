# Hub

Firm-internal work and the index of client engagements.

## Data boundary

Enterprise-seat clients: registry metadata only. Never read their files, memory or transcripts from here, and don't start their sessions from here: `cc` refuses, because the output would come back into this account. Tell the user what needs doing there; they start it with `cc` in the client root.

No-seat clients can be handed work with `cc -a <key> --at-root -p "<task>"`.

No-seat clients: their code may be read through `additionalDirectories`. Their `CLAUDE.md` rules don't apply to hub sessions.

## Engagements

<!-- BEGIN GENERATED: Sync-Dossier -->
<!-- END GENERATED -->
