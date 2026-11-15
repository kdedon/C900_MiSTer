# Notes for the README index (writer A -> writer B)

Files written, all in this directory: PDMAC_8716.md, FDC_8723.md,
U54_FPLA.md, HDC_CARD.md, HR_CARD_LOGIC.md, LR_CARD_LOGIC.md,
KEYBOARD.md. No extra chip file was added.

Custom or undocumented parts found during research and where they are
covered, so the index can point at them:

- U80-U83 (8716 address chips) and U84/U85: PDMAC_8716.md section 4.
- The Commodore 8716 test interposer rig (/BOTH jumper): PDMAC_8716.md
  section 6, as history for the O-37 end-of-block question.
- The 311075 keyboard interface piggyback board (LS299 + 2 x LS74A +
  LS125): KEYBOARD.md sections 3-4 (not a chip file of its own).
- HDC card U8 PAL16R6 and the 8049 "CCCP" firmware: HDC_CARD.md.
- HR card: U262 82S105 SYN, ZSEL/ZARB/ZMEMC/ZCAS PALs, U312, U755,
  U756/U757 PAL20X8: HR_CARD_LOGIC.md. All undumped; programs INFERRED.
- LR card: U18 ZRSEL and U22 4A75 (dumped), U13 PAL16R6A (undumped),
  U2 character ROM (dumped): LR_CARD_LOGIC.md.
- Motherboard U54 FPLA (dumped): U54_FPLA.md.

Cross-file conventions: every file opens with a legend line (SOURCED /
INFERRED / OPEN) and names its RTL; HDC_CARD.md and FDC_8723.md refer
to PDMAC_8716.md sections 6-7 for the shared-bus and _IREQ story.
Inventions mentioned: the RAM card (U54_FPLA.md section 4, D-MEM-8) and
the serial mouse (HR_CARD_LOGIC.md section 6, D-SER-5), both marked
INVENTED with their DECISIONS rows.

Superseded theories recorded as history: 8716 /CS and /CREQ pins and
the WD2010 BDRQ (PDMAC_8716.md 2, HDC_CARD.md 1); the 8049 at 10 MHz
(HDC_CARD.md 1); the 8716 vector as decimal 80 (PDMAC_8716.md 6); the
HR Rev 3 sheet set (HR_CARD_LOGIC.md 1); the Z8000HR spec's PD6/PD7
keyboard wiring and interlocked handshake (KEYBOARD.md 1, 4); the LR
"keyboard SIO" reading (LR_CARD_LOGIC.md 1).
