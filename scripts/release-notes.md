Performance engine update: shared metadata and lightweight row indexes, reusable sort orders across queries, radix sorting for size/date, constant-time reversal, faster ASCII filename matching with Unicode fallback, and background selection restoration. Live changes preserve base sort orders.

The release pipeline checks a million synthetic records in optimized engine tests and the real native table, alongside filesystem create/rename/delete, native rendering and installer checks. See docs/PERFORMANCE.md for methodology and limitations. Speed parity with Windows Everything has not been established.

Download **Anyseek.dmg**, double-click it, and drag **Anyseek.app** onto **Applications**. Eject the disk image and open Anyseek. No Terminal or build tools are needed. Requires macOS 13+, Apple Silicon or Intel.

The application is ad-hoc signed, not Apple-notarized; macOS may require Privacy & Security → Open Anyway. This remains an independent implementation with incomplete Everything feature parity.
