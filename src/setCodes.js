/* Printed expansion code -> set name, for resolving a scanned card's set
   symbol. This used to come from pokemontcg.io's ptcgoCode field; PPT's set
   list carries no codes, so the modern era lives here as data. Only codes
   that are certain belong in this table — a wrong entry names the wrong set
   on a card that then prices as the wrong card, while a missing entry just
   falls through to matching the set's printed name, which the scanner also
   reads. Add new sets as they release. */
export const SET_CODES = {
  // Scarlet & Violet era
  SVI: "Scarlet & Violet",
  PAL: "Paldea Evolved",
  OBF: "Obsidian Flames",
  MEW: "151",
  PAR: "Paradox Rift",
  PAF: "Paldean Fates",
  TEF: "Temporal Forces",
  TWM: "Twilight Masquerade",
  SFA: "Shrouded Fable",
  SCR: "Stellar Crown",
  SSP: "Surging Sparks",
  PRE: "Prismatic Evolutions",
  JTG: "Journey Together",
  DRI: "Destined Rivals",
  BLK: "Black Bolt",
  WHT: "White Flare",
  SVP: "Scarlet & Violet Black Star Promos",
  // Sword & Shield era
  SSH: "Sword & Shield",
  RCL: "Rebel Clash",
  DAA: "Darkness Ablaze",
  VIV: "Vivid Voltage",
  BST: "Battle Styles",
  CRE: "Chilling Reign",
  EVS: "Evolving Skies",
  FST: "Fusion Strike",
  BRS: "Brilliant Stars",
  ASR: "Astral Radiance",
  PGO: "Pokemon GO",
  LOR: "Lost Origin",
  SIT: "Silver Tempest",
  CRZ: "Crown Zenith",
  SWSH: "SWSH Black Star Promos",
};
