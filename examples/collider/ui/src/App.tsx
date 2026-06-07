/**
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { useState, useRef, useEffect, useCallback, useMemo } from 'react';
import { flushSync } from 'react-dom';
import { Turtle, Rabbit } from 'lucide-react';
import IconButton from '@mui/material/IconButton';
import TuneIcon from '@mui/icons-material/Tune';
import Tooltip from '@mui/material/Tooltip';
import { ModelSelector, SettingsPanel, TimingIndicator, AudioMeter, ResourceOnboardingModal, TransportControls, PromptSurface, calculateWeights, ALL_SUGGESTIONS, DEFAULT_TEMPERATURE, DEFAULT_TOPK, DEFAULT_CFG_MUSICCOCA, DEFAULT_CFG_DRUMS, DEFAULT_UNMASK_WIDTH, DEFAULT_VOLUME, COLLIDER_CFG_NOTES, COLLIDER_CFG_MUSICCOCA } from '@magenta-rt/common';
import type { PromptNode, ListenerNode } from '@magenta-rt/common';
import { CONFABULATOR_BANKS } from './confabulatorBank';
import type { ConfabulatorBank, ConfabulatorBankItem } from './confabulatorBank';


// ─── WebKit bridge ───────────────────────────────────────────────────────────

declare global {
  interface Window {
    updateState: (state: any) => void;
    webkit?: {
      messageHandlers?: {
        auHost?: { postMessage: (msg: any) => void };
      };
    };
  }
}

const post = (msg: any) => window.webkit?.messageHandlers?.auHost?.postMessage(msg);

const MAX_ENGINE_PROMPTS = 6;
const PCA_NODE_LABEL = 'pca';
const CONFABULATOR_DEFAULT_BUFFER_SIZE = 1;
const TEXT_EMBEDDING_DIM = 768;

type ConfabulatorPromptNode = PromptNode & {
  isBank?: boolean;
  bankId?: string;
  bankEmbedding?: number[];
  textEmbedding?: number[];
};

type ParamsState = {
  temperature: number;
  topk: number;
  cfgnotes: number;
  cfgmusiccoca: number;
  cfgdrums: number;
  unmaskwidth: number;
  buffersize: number;
  volume: number;
  drumless: boolean;
  seedrotation: number;
  pca_coeff_0: number;
  pca_coeff_1: number;
  pca_coeff_2: number;
  pca_coeff_3: number;
  pca_coeff_4: number;
  pca_coeff_5: number;
};

const PARAM_STATE_KEYS: Partial<Record<number, keyof ParamsState>> = {
  0: 'temperature',
  1: 'topk',
  3: 'cfgmusiccoca',
  4: 'cfgnotes',
  7: 'unmaskwidth',
  8: 'buffersize',
  39: 'drumless',
  47: 'seedrotation',
  48: 'cfgdrums',
  33: 'pca_coeff_0',
  34: 'pca_coeff_1',
  35: 'pca_coeff_2',
  36: 'pca_coeff_3',
  37: 'pca_coeff_4',
  38: 'pca_coeff_5',
};

const PARAM_KEY_TO_ADDRESS = Object.entries(PARAM_STATE_KEYS).reduce((map, [address, key]) => {
  if (key) map[key] = Number(address);
  return map;
}, {} as Partial<Record<keyof ParamsState, number>>);

const PCA_PARAM_ADDRESSES = [33, 34, 35, 36, 37, 38] as const;

type FxState = {
  wet: number;
  drive: number;
  fold: number;
  crush: number;
  ring: number;
  comb: number;
  body: number;
  smear: number;
  stutter: number;
  pitch: number;
  harmonics: number;
  noise: number;
  rvqForce: number;
  rvqBreathe: number;
  rvqMemory: number;
  rvqCoarse: number;
  rvqFine: number;
  rvqSweep: number;
  rvqHold: number;
  rvqInvert: number;
  rvqJitter: number;
  rvqStride: number;
};

const RVQ_KEYS = [
  'rvqForce',
  'rvqBreathe',
  'rvqMemory',
  'rvqCoarse',
  'rvqFine',
  'rvqSweep',
  'rvqHold',
  'rvqInvert',
  'rvqJitter',
  'rvqStride',
] as const;

type RvqKey = typeof RVQ_KEYS[number];
type RvqValues = Pick<FxState, RvqKey>;
type RvqPedalMode = 'toggle' | 'hold' | 'latch';
type RvqPedalId = 'freeze' | 'misremember' | 'shedSkin' | 'hollow' | 'spill' | 'possessed' | 'echoCore';

type RvqPedalState = Record<RvqPedalId, {
  active: boolean;
  mix: number;
  mode: RvqPedalMode;
}>;

type RvqPedalDef = {
  id: RvqPedalId;
  label: string;
  result: string;
  values: Partial<RvqValues>;
};

type RecorderState = {
  rolling: boolean;
  rollingSeconds: number;
  availableSeconds: number;
  recording: boolean;
  recordingSeconds: number;
  maxLiveSeconds: number;
  status?: string;
  filePath?: string;
  sidecarPath?: string;
  error?: string;
};

type PerformanceState = {
  drift: number;
  snapback: number;
};

type TextLabState = {
  warp: number;
  scramble: number;
  morph: number;
  oppose: number;
  scan: number;
  gravity: number;
};

type TextLabStatus = 'RAW' | 'ENC' | 'VEC' | 'WAIT' | 'SLOT' | 'TEXT';
type SourceStatus = 'EMPTY' | 'LOAD' | 'EMBED' | 'ERR';

type SavedSettingsPrompt = Pick<ConfabulatorPromptNode, 'id' | 'x' | 'y' | 'label' | 'colorIndex' | 'isAudio' | 'isBank' | 'bankId' | 'bankEmbedding' | 'textEmbedding'>;

type SavedSettingsBank = {
  id: string;
  name: string;
  savedAt: number;
  params: ParamsState;
  fx: FxState;
  performance: PerformanceState;
  textLab: TextLabState;
  rvqPedals?: RvqPedalState;
  prompts: SavedSettingsPrompt[];
  listener: ListenerNode;
  selectedBallId: number | null;
  selectedBankSetId: string;
  selectedBankId: string;
  sliderPos: number;
  collisionsEnabled: boolean;
};

type PromptPayload = {
  text: string;
  weight: number;
  kind: 'text' | 'audio' | 'bank';
  embedding?: number[];
};

type AgentStatus = {
  enabled?: boolean;
  protocol?: string;
  host?: string;
  port?: number;
  lastCommand?: string;
};

type AgentEvent = {
  at: string;
  t: number;
  direction: 'in' | 'out';
  payload: unknown;
};

const DEFAULT_FX_STATE: FxState = {
  wet: 0,
  drive: 0,
  fold: 0,
  crush: 0,
  ring: 0,
  comb: 0,
  body: 0,
  smear: 0,
  stutter: 0,
  pitch: 0.5,
  harmonics: 0,
  noise: 0,
  rvqForce: 0,
  rvqBreathe: 0,
  rvqMemory: 0,
  rvqCoarse: 0,
  rvqFine: 0,
  rvqSweep: 0,
  rvqHold: 0,
  rvqInvert: 0,
  rvqJitter: 0,
  rvqStride: 0,
};

const DEFAULT_PERFORMANCE_STATE: PerformanceState = {
  drift: 0,
  snapback: 0,
};

const DEFAULT_TEXT_LAB_STATE: TextLabState = {
  warp: 0,
  scramble: 0,
  morph: 0,
  oppose: 0,
  scan: 0,
  gravity: 0.35,
};

const RVQ_PEDAL_DEFS: RvqPedalDef[] = [
  {
    id: 'freeze',
    label: 'FREEZE',
    result: 'Locks the RVQ stack into glassy held spectral material.',
    values: { rvqForce: 0.28, rvqBreathe: 0.12, rvqMemory: 0.28, rvqHold: 0.92, rvqJitter: 0.04 },
  },
  {
    id: 'misremember',
    label: 'MISREMEMBER',
    result: 'Pushes short memory until the model recalls the wrong thing.',
    values: { rvqForce: 0.38, rvqBreathe: 0.42, rvqMemory: 0.88, rvqHold: 0.38, rvqStride: 0.18 },
  },
  {
    id: 'shedSkin',
    label: 'SHED SKIN',
    result: 'Keeps the gesture while tearing at fine RVQ texture.',
    values: { rvqForce: 0.44, rvqFine: 0.92, rvqCoarse: 0.08, rvqJitter: 0.28, rvqBreathe: 0.22 },
  },
  {
    id: 'hollow',
    label: 'HOLLOW',
    result: 'Inverts and thins the spectral body into a carved-out shape.',
    values: { rvqForce: 0.42, rvqCoarse: 0.48, rvqFine: 0.12, rvqInvert: 0.84, rvqBreathe: 0.16 },
  },
  {
    id: 'spill',
    label: 'SPILL',
    result: 'Sweeps through codebook neighborhoods so the sound leaks sideways.',
    values: { rvqForce: 0.36, rvqSweep: 0.9, rvqStride: 0.82, rvqBreathe: 0.3, rvqJitter: 0.26 },
  },
  {
    id: 'possessed',
    label: 'POSSESSED',
    result: 'Stacks coarse and fine corruption until the model fights itself.',
    values: { rvqForce: 0.94, rvqMemory: 0.8, rvqCoarse: 0.48, rvqFine: 0.78, rvqInvert: 0.48, rvqJitter: 0.86 },
  },
  {
    id: 'echoCore',
    label: 'ECHO CORE',
    result: 'Smears the present with the recent RVQ memory.',
    values: { rvqForce: 0.24, rvqBreathe: 0.24, rvqMemory: 0.92, rvqHold: 0.22, rvqFine: 0.1 },
  },
];

function createDefaultRvqPedals(): RvqPedalState {
  return RVQ_PEDAL_DEFS.reduce((state, pedal) => {
    state[pedal.id] = {
      active: false,
      mix: 0.7,
      mode: 'toggle',
    };
    return state;
  }, {} as RvqPedalState);
}

function cloneRvqPedals(state: RvqPedalState): RvqPedalState {
  return RVQ_PEDAL_DEFS.reduce((next, pedal) => {
    const existing = state[pedal.id];
    const mode = existing?.mode === 'hold' || existing?.mode === 'latch' ? existing.mode : 'toggle';
    next[pedal.id] = {
      active: !!existing?.active,
      mix: Number.isFinite(existing?.mix) ? Math.max(0, Math.min(1, existing.mix)) : 0.7,
      mode,
    };
    return next;
  }, {} as RvqPedalState);
}

const DEFAULT_RECORDER_STATE: RecorderState = {
  rolling: true,
  rollingSeconds: 30,
  availableSeconds: 0,
  recording: false,
  recordingSeconds: 0,
  maxLiveSeconds: 600,
  status: 'idle',
};

// ─── Defaults ────────────────────────────────────────────────────────────────

const DEFAULT_PHYSICS_SPEED = 0.5;

/** Fisher-Yates shuffle (in place). */
function shuffle<T>(arr: T[]): T[] {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

/** A shuffled copy of ALL_SUGGESTIONS used as a deck. Drum-forward prompts are
 *  moved after the first pass so startup is drumless by default. */
const DRUM_FORWARD_PROMPT_RE = /\b(?:afrobeat|batucada|beat|beats|club|darbuka|disco|drum|drums|garage rock|groove|hip hop|idm|percussion|polyrhythm|polyrhythms|salsa|samba|snare|tabla|trap)\b/i;
const DRUMLESS_SUGGESTIONS = ALL_SUGGESTIONS.filter((label) => !DRUM_FORWARD_PROMPT_RE.test(label));
const DRUM_FORWARD_SUGGESTIONS = ALL_SUGGESTIONS.filter((label) => DRUM_FORWARD_PROMPT_RE.test(label));
const SHUFFLED_SUGGESTIONS = [
  ...shuffle([...DRUMLESS_SUGGESTIONS]),
  ...shuffle([...DRUM_FORWARD_SUGGESTIONS]),
];
const INITIAL_PROMPT_LABELS = SHUFFLED_SUGGESTIONS.slice(0, 3);
const ALL_CONFABULATOR_BANK_ITEMS = CONFABULATOR_BANKS.flatMap((bank) => bank.items);
const INITIAL_EMBEDDING_ITEMS = shuffle([...ALL_CONFABULATOR_BANK_ITEMS]).slice(0, 3);
const SETTINGS_BANK_STORAGE_KEY = 'confabulator.settingsBanks.v1';
const SOURCE_BANK_STORAGE_KEY = 'confabulator.sourceEmbeds.v1';
const SOURCE_BANK_ID = 'source-various';
const MAX_SETTINGS_BANKS = 16;
const MAX_SOURCE_BANK_ITEMS = 64;
const DEFAULT_DRUMLESS = true;

const INITIAL_LISTENER: ListenerNode = { x: 0, y: 0 }; // recalculated on mount

// ─── Speed slider mapping ────────────────────────────────────────────────────
// Exponential curve so most of the slider is dedicated to slow speeds.
// slider 0–1 → speed 0–MAX  via  t^exp

const SPEED_CURVE_EXP = 2;

const sliderToSpeed = (t: number) => Math.pow(t, SPEED_CURVE_EXP) * DEFAULT_PHYSICS_SPEED;
const speedToSlider = (s: number) => Math.pow(s / DEFAULT_PHYSICS_SPEED, 1 / SPEED_CURVE_EXP);

function formatDial(value: number, digits = 2) {
  return Number.isInteger(value) ? String(value) : value.toFixed(digits);
}

function hashString(text: string) {
  let hash = 2166136261;
  for (let i = 0; i < text.length; i += 1) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function toMessageSafeObject(value: unknown) {
  return JSON.parse(JSON.stringify(value));
}

function driftEmbedding(base: number[], key: string, performance: PerformanceState) {
  if (performance.drift <= 0.0001 && performance.snapback <= 0.0001) return base;
  const seed = hashString(key);
  const now = Date.now() * 0.001;
  const snapPulse = performance.snapback > 0
    ? Math.pow(0.5 + 0.5 * Math.sin(now * (0.18 + performance.snapback * 1.35) + seed * 0.00001), 3)
    : 0;
  const walkAmount = performance.drift * (1.0 - performance.snapback * snapPulse);
  if (walkAmount <= 0.0001) return base;

  let baseNorm = 0;
  let nextNorm = 0;
  const next = base.map((value, index) => {
    baseNorm += value * value;
    const a = Math.sin(index * 12.9898 + seed * 0.000173 + now * (0.13 + performance.drift * 1.7));
    const b = Math.sin(index * 78.233 + seed * 0.000311 - now * (0.07 + performance.drift * 0.9));
    const warped = value + (a * 0.72 + b * 0.28) * walkAmount * 0.95;
    nextNorm += warped * warped;
    return warped;
  });

  const scale = Math.sqrt(baseNorm) / Math.max(1e-6, Math.sqrt(nextNorm));
  return next.map((value) => value * scale);
}

function vectorNorm(values: number[]) {
  return Math.sqrt(values.reduce((sum, value) => sum + value * value, 0));
}

function textLabEmbedding(base: number[], key: string, lab: TextLabState, target?: number[]) {
  const active =
    lab.warp > 0.0001 ||
    lab.scramble > 0.0001 ||
    lab.morph > 0.0001 ||
    lab.oppose > 0.0001 ||
    lab.scan > 0.0001;
  if (!active) return base;

  const useTarget = target?.length === base.length;
  const baseNorm = Math.max(1e-6, vectorNorm(base));
  const targetScale = useTarget ? baseNorm / Math.max(1e-6, vectorNorm(target!)) : 1;
  const avgMagnitude = baseNorm / Math.sqrt(Math.max(1, base.length));
  const seed = hashString(key);
  const now = Date.now() * 0.001;

  const next = base.map((value, index) => {
    const targetValue = useTarget ? target![index] * targetScale : 0;
    let warped = value;

    if (useTarget && lab.morph > 0.0001) {
      warped = warped * (1 - lab.morph) + targetValue * lab.morph;
    }
    if (useTarget && lab.oppose > 0.0001) {
      warped -= targetValue * lab.oppose * 1.15;
    }
    if (lab.warp > 0.0001) {
      const bent = Math.tanh(value / Math.max(1e-6, avgMagnitude) * (1.2 + lab.warp * 2.8)) * avgMagnitude;
      warped += (bent - value) * lab.warp * 1.8;
    }
    if (lab.scramble > 0.0001) {
      const a = Math.sin(index * 92.173 + seed * 0.00031);
      const b = Math.sin(index * 13.313 + seed * 0.00017);
      warped += (a * 0.72 + b * 0.28) * avgMagnitude * lab.scramble * 2.4;
    }
    if (lab.scan > 0.0001) {
      const wave = Math.sin(index * (0.071 + lab.scan * 0.09) + now * (0.9 + lab.scan * 5.2) + seed * 0.00001);
      warped += wave * avgMagnitude * lab.scan * 1.8;
    }
    if (lab.gravity > 0.0001) {
      warped = warped * (1 - lab.gravity) + value * lab.gravity;
    }
    return warped;
  });

  const nextNorm = Math.max(1e-6, vectorNorm(next));
  return next.map((value) => value * (baseNorm / nextNorm));
}

function engineSlotForPrompt(prompts: ConfabulatorPromptNode[], promptId: number) {
  const audioIdx = prompts.findIndex((prompt) => prompt.isAudio);
  if (audioIdx !== -1) {
    if (prompts[audioIdx].id === promptId) return 0;
    let dest = 1;
    for (let i = 0; i < prompts.length; i += 1) {
      if (i === audioIdx) continue;
      if (dest >= MAX_ENGINE_PROMPTS) return -1;
      if (prompts[i].id === promptId) return dest;
      dest += 1;
    }
    return -1;
  }

  const index = prompts.findIndex((prompt) => prompt.id === promptId);
  return index >= 0 && index < MAX_ENGINE_PROMPTS ? index : -1;
}

function randomBankItem(items: ConfabulatorBankItem[] = ALL_CONFABULATOR_BANK_ITEMS) {
  if (items.length === 0) return undefined;
  return items[Math.floor(Math.random() * items.length)];
}

function displayBankLabel(item: ConfabulatorBankItem) {
  return item.label
    .replace(/^Source:\s*/i, '')
    .replace(/\s+/g, ' ')
    .slice(0, 96);
}

function isTextLabNeutral(lab: TextLabState) {
  return lab.warp <= 0.0001 &&
    lab.scramble <= 0.0001 &&
    lab.morph <= 0.0001 &&
    lab.oppose <= 0.0001 &&
    lab.scan <= 0.0001;
}

function loadSavedSettingsBanks() {
  if (typeof window === 'undefined') return [];
  try {
    const raw = window.localStorage.getItem(SETTINGS_BANK_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((bank): bank is SavedSettingsBank => bank && typeof bank.id === 'string' && typeof bank.name === 'string')
      .slice(0, MAX_SETTINGS_BANKS);
  } catch {
    return [];
  }
}

function saveSettingsBanksToStorage(banks: SavedSettingsBank[]) {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(SETTINGS_BANK_STORAGE_KEY, JSON.stringify(banks.slice(0, MAX_SETTINGS_BANKS)));
}

function loadSourceBankItems() {
  if (typeof window === 'undefined') return [];
  try {
    const raw = window.localStorage.getItem(SOURCE_BANK_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((item): item is ConfabulatorBankItem =>
        item &&
        typeof item.id === 'string' &&
        typeof item.label === 'string' &&
        Array.isArray(item.embedding) &&
        item.embedding.length === TEXT_EMBEDDING_DIM
      )
      .map((item): ConfabulatorBankItem => ({
        id: item.id,
        label: item.label,
        bank: typeof item.bank === 'string' ? item.bank : SOURCE_BANK_ID,
        features: item.features,
        root: item.root,
        brightness: item.brightness,
        density: item.density,
        rhythm: item.rhythm,
        styleTokens: Array.isArray(item.styleTokens) ? item.styleTokens : [],
        embedding: item.embedding,
      }))
      .slice(0, MAX_SOURCE_BANK_ITEMS);
  } catch {
    return [];
  }
}

function saveSourceBankItemsToStorage(items: ConfabulatorBankItem[]) {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(SOURCE_BANK_STORAGE_KEY, JSON.stringify(items.slice(0, MAX_SOURCE_BANK_ITEMS)));
}

function ConfabulatorSlider({
  label,
  value,
  min,
  max,
  step,
  onChange,
  digits = 2,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
  digits?: number;
}) {
  return (
    <label className="confabulator-slider">
      <span>
        <b>{label}</b>
        <em>{formatDial(value, digits)}</em>
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(event) => onChange(Number(event.currentTarget.value))}
      />
    </label>
  );
}

function clampToStage(value: number, min: number, max: number) {
  if (max < min) return (min + max) / 2;
  return Math.max(min, Math.min(max, value));
}

/** Build a visible triangle of prompts centered in the available canvas. */
function buildInitialLayout(w: number, h: number) {
  const padX = Math.max(28, Math.min(72, w * 0.1, w / 4));
  const padY = Math.max(24, Math.min(64, h * 0.2, h / 3));
  const minX = padX;
  const maxX = Math.max(minX, w - padX);
  const minY = padY;
  const maxY = Math.max(minY, h - padY);
  const cx = clampToStage(w / 2, minX, maxX);
  const cy = clampToStage(h / 2, minY, maxY);
  const usableW = Math.max(1, maxX - minX);
  const usableH = Math.max(1, maxY - minY);
  const r = Math.max(18, Math.min(usableW * 0.32, usableH * 0.48));
  // 3 vertices at -90°, 30°, 150° (top, bottom-right, bottom-left)
  const angles = [-Math.PI / 2, Math.PI / 6, (5 * Math.PI) / 6];
  const initialItems = INITIAL_EMBEDDING_ITEMS.length >= 3 ? INITIAL_EMBEDDING_ITEMS : [];
  const prompts: ConfabulatorPromptNode[] = initialItems.length > 0
    ? initialItems.map((item, i) => ({
      id: i,
      x: clampToStage(cx + r * Math.cos(angles[i]), minX, maxX),
      y: clampToStage(cy + r * Math.sin(angles[i]), minY, maxY),
      label: displayBankLabel(item),
      colorIndex: i,
      isBank: true,
      bankId: item.id,
      bankEmbedding: item.embedding,
    }))
    : INITIAL_PROMPT_LABELS.map((label, i) => ({
      id: i,
      x: clampToStage(cx + r * Math.cos(angles[i]), minX, maxX),
      y: clampToStage(cy + r * Math.sin(angles[i]), minY, maxY),
      label,
      colorIndex: i,
    }));
  const listener: ListenerNode = { x: cx, y: cy };
  return { prompts, listener };
}

function buildStartupLayout() {
  const width = typeof window === 'undefined' ? 1000 : Math.max(640, window.innerWidth);
  const height = typeof window === 'undefined'
    ? 320
    : Math.max(220, Math.min(460, window.innerHeight * 0.34));
  return buildInitialLayout(width, height);
}

// ─── App ─────────────────────────────────────────────────────────────────────

function App() {
  const initialLayoutRef = useRef<ReturnType<typeof buildInitialLayout> | null>(null);
  if (!initialLayoutRef.current) {
    initialLayoutRef.current = buildStartupLayout();
  }
  const [prompts, setPrompts] = useState<ConfabulatorPromptNode[]>(() => initialLayoutRef.current?.prompts ?? []);
  const [listener, setListener] = useState<ListenerNode>(() => initialLayoutRef.current?.listener ?? INITIAL_LISTENER);
  const layoutInitialized = useRef(false);
  const [selectedBallId, setSelectedBallId] = useState<number | null>(() => initialLayoutRef.current?.prompts[0]?.id ?? null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [audioLevel, setAudioLevel] = useState(0);
  const [sliderPos, setSliderPos] = useState(0.5);
  const physicsSpeed = sliderToSpeed(sliderPos);
  const [collisionsEnabled, setCollisionsEnabled] = useState(true);
  const [hasThrown, setHasThrown] = useState(false);
  const [debug, setDebug] = useState(false);
  const [modelName, setModelName] = useState('No model loaded');
  const [localModels, setLocalModels] = useState<string[]>([]);
  const [remoteModels, setRemoteModels] = useState<string[]>([]);
  const [downloadProgress, setDownloadProgress] = useState<any>(null);
  const [downloadPath, setDownloadPath] = useState("~/Documents/Magenta/magenta-rt-v2");
  const [resourcesMissing, setResourcesMissing] = useState(false);
  const [resourcesProgress, setResourcesProgress] = useState<any>(null);
  const [isFetchingModels, setIsFetchingModels] = useState(true);


  // Metrics state
  const [metrics, setMetrics] = useState({ frameMs: 0, bufferAvail: 0, bufferCap: 0, droppedFrames: 0 });

  // Settings Drawer states
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [paramsState, setParamsState] = useState<ParamsState>({
    temperature: DEFAULT_TEMPERATURE,
    topk: DEFAULT_TOPK,
    cfgnotes: COLLIDER_CFG_NOTES,
    cfgmusiccoca: COLLIDER_CFG_MUSICCOCA,
    cfgdrums: DEFAULT_CFG_DRUMS,
    unmaskwidth: DEFAULT_UNMASK_WIDTH,
    buffersize: CONFABULATOR_DEFAULT_BUFFER_SIZE,
    volume: DEFAULT_VOLUME,
    drumless: DEFAULT_DRUMLESS,
    seedrotation: 0,
    pca_coeff_0: 0,
    pca_coeff_1: 0,
    pca_coeff_2: 0,
    pca_coeff_3: 0,
    pca_coeff_4: 0,
    pca_coeff_5: 0,
  });
  const [fxState, setFxState] = useState<FxState>(DEFAULT_FX_STATE);
  const [rvqPedals, setRvqPedals] = useState<RvqPedalState>(createDefaultRvqPedals);
  const [recorderState, setRecorderState] = useState<RecorderState>(DEFAULT_RECORDER_STATE);
  const [agentStatus, setAgentStatus] = useState<AgentStatus>({});
  const [agentCommand, setAgentCommand] = useState<any>(null);
  const [agentCommandPulse, setAgentCommandPulse] = useState(0);
  const [performanceState, setPerformanceState] = useState<PerformanceState>(DEFAULT_PERFORMANCE_STATE);
  const [textLabState, setTextLabState] = useState<TextLabState>(DEFAULT_TEXT_LAB_STATE);
  const [textLabStatus, setTextLabStatus] = useState<TextLabStatus>('RAW');
  const [sourceStatus, setSourceStatus] = useState<SourceStatus>('EMPTY');
  const [sourceName, setSourceName] = useState('');
  const [sourceBankItems, setSourceBankItems] = useState<ConfabulatorBankItem[]>(loadSourceBankItems);
  const [settingsBanks, setSettingsBanks] = useState<SavedSettingsBank[]>(loadSavedSettingsBanks);
  const [selectedSettingsBankId, setSelectedSettingsBankId] = useState('');
  const startupBankId = initialLayoutRef.current?.prompts[0]?.bankId;
  const startupBankSetId = startupBankId
    ? CONFABULATOR_BANKS.find((bank) => bank.items.some((item) => item.id === startupBankId))?.id
    : undefined;
  const [selectedBankSetId, setSelectedBankSetId] = useState(startupBankSetId ?? CONFABULATOR_BANKS[0]?.id ?? '');
  const [selectedBankId, setSelectedBankId] = useState(startupBankId ?? CONFABULATOR_BANKS[0]?.items[0]?.id ?? '');
  const bankSets = useMemo<ConfabulatorBank[]>(() => {
    if (sourceBankItems.length === 0) return CONFABULATOR_BANKS;
    return [{
      id: SOURCE_BANK_ID,
      label: 'VARIOUS',
      source: 'Audio embeddings created inside CONFABULATOR.',
      license: 'Local audio selected by user',
      items: sourceBankItems,
    }, ...CONFABULATOR_BANKS];
  }, [sourceBankItems]);
  const allBankItems = useMemo(() => bankSets.flatMap((bank) => bank.items), [bankSets]);
  const activeBank = bankSets.find((bank) => bank.id === selectedBankSetId) ?? bankSets[0];
  const activeBankItems = activeBank?.items ?? [];
  const selectedBankItem = activeBankItems.find((bankItem) => bankItem.id === selectedBankId) ?? activeBankItems[0];
  const selectedPrompt = prompts.find((prompt) => prompt.id === selectedBallId);
  const canApplyBankToSelected = selectedBallId !== null && !!selectedPrompt;
  const canCaptureSelectedText = selectedBallId !== null && !!selectedPrompt && !selectedPrompt.isAudio && !selectedPrompt.isBank && !selectedPrompt.textEmbedding && selectedPrompt.label.trim().length > 0;
  const canReleaseSelectedText = !!selectedPrompt?.textEmbedding;
  const textLabStatusLabel: TextLabStatus = selectedPrompt?.textEmbedding ? 'VEC' : textLabStatus;
  const canLoadSettingsBank = settingsBanks.some((bank) => bank.id === selectedSettingsBankId);

  useEffect(() => {
    if (!activeBankItems.some((item) => item.id === selectedBankId)) {
      setSelectedBankId(activeBankItems[0]?.id ?? '');
    }
  }, [activeBankItems, selectedBankId]);

  useEffect(() => {
    saveSettingsBanksToStorage(settingsBanks);
  }, [settingsBanks]);

  useEffect(() => {
    saveSourceBankItemsToStorage(sourceBankItems);
  }, [sourceBankItems]);

  // ─── Measure prompt surface and build initial layout ─────────────────
  const promptSurfaceRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (layoutInitialized.current) return;
    let cancelled = false;
    let frame = 0;
    let timeout = 0;
    let attempts = 0;

    const tryInitializeLayout = () => {
      const el = promptSurfaceRef.current;
      if (layoutInitialized.current || cancelled) return;
      if (!el) {
        attempts += 1;
        if (attempts < 80) {
          timeout = window.setTimeout(() => {
            frame = requestAnimationFrame(tryInitializeLayout);
          }, 25);
        }
        return;
      }
      const { width, height } = el.getBoundingClientRect();
      if (width > 0 && height > 0) {
        const layout = buildInitialLayout(width, height);
        setPrompts(layout.prompts);
        setListener(layout.listener);
        const firstPrompt = layout.prompts[0];
        if (firstPrompt) {
          setSelectedBallId(firstPrompt.id);
          if (firstPrompt.bankId) {
            const owningBank = CONFABULATOR_BANKS.find((bank) =>
              bank.items.some((item) => item.id === firstPrompt.bankId)
            );
            if (owningBank) {
              setSelectedBankSetId(owningBank.id);
              setSelectedBankId(firstPrompt.bankId);
            }
          }
        }
        layoutInitialized.current = true;
        return;
      }

      attempts += 1;
      if (attempts < 80) {
        timeout = window.setTimeout(() => {
          frame = requestAnimationFrame(tryInitializeLayout);
        }, 25);
      }
    };

    frame = requestAnimationFrame(tryInitializeLayout);
    return () => {
      cancelled = true;
      cancelAnimationFrame(frame);
      window.clearTimeout(timeout);
    };
  }, []);

  const sendParamChange = (index: number, value: number) => {
    const key = PARAM_STATE_KEYS[index];
    if (key) {
      setParamsState((previous) => ({
        ...previous,
        [key]: key === 'drumless' ? value > 0.5 : value,
      }));
    }
    post({ type: 'param', index, value });
  };

  const sendFxChange = (key: keyof FxState, value: number) => {
    setFxState((previous) => ({ ...previous, [key]: value }));
    post({ type: 'fx', key, value });
  };

  const readRvqValues = (source: FxState = fxState): RvqValues => {
    const values = {} as RvqValues;
    RVQ_KEYS.forEach((key) => {
      values[key] = source[key];
    });
    return values;
  };

  const sendRvqValues = (values: Partial<RvqValues>) => {
    RVQ_KEYS.forEach((key) => {
      const value = values[key];
      if (typeof value === 'number' && Number.isFinite(value)) {
        sendFxChange(key, Math.max(0, Math.min(1, value)));
      }
    });
  };

  const hasActiveRvqPedal = (state: RvqPedalState) =>
    RVQ_PEDAL_DEFS.some((pedal) => state[pedal.id]?.active);

  const mixRvqPedalValues = (base: RvqValues, state: RvqPedalState): RvqValues => {
    const next = { ...base };
    RVQ_PEDAL_DEFS.forEach((pedal) => {
      const pedalState = state[pedal.id];
      if (!pedalState?.active) return;
      const mix = Math.max(0, Math.min(1, pedalState.mix));
      (Object.entries(pedal.values) as [RvqKey, number][]).forEach(([key, target]) => {
        next[key] = next[key] * (1 - mix) + target * mix;
      });
    });
    return next;
  };

  const applyRvqPedalLayer = (nextPedals: RvqPedalState) => {
    if (!hasActiveRvqPedal(nextPedals)) {
      const base = rvqPedalBaseRef.current;
      rvqPedalBaseRef.current = null;
      if (base) {
        sendRvqValues(base);
      }
      return;
    }

    const base = rvqPedalBaseRef.current ?? readRvqValues();
    rvqPedalBaseRef.current = base;
    sendRvqValues(mixRvqPedalValues(base, nextPedals));
  };

  const setAllRvqPedalsInactive = (restoreBase = true) => {
    const next = cloneRvqPedals(rvqPedals);
    RVQ_PEDAL_DEFS.forEach((pedal) => {
      next[pedal.id].active = false;
    });
    setRvqPedals(next);
    if (restoreBase) {
      applyRvqPedalLayer(next);
    } else {
      rvqPedalBaseRef.current = null;
    }
  };

  const updateRvqPedal = (id: RvqPedalId, patch: Partial<RvqPedalState[RvqPedalId]>) => {
    const next = cloneRvqPedals(rvqPedals);
    next[id] = { ...next[id], ...patch };
    setRvqPedals(next);
    applyRvqPedalLayer(next);
  };

  const handleRvqPedalClick = (id: RvqPedalId) => {
    const mode = rvqPedals[id].mode;
    if (mode === 'hold') return;
    updateRvqPedal(id, { active: !rvqPedals[id].active });
  };

  const handleRvqPedalPointerDown = (id: RvqPedalId) => {
    if (rvqPedals[id].mode === 'hold') {
      updateRvqPedal(id, { active: true });
    }
  };

  const handleRvqPedalPointerUp = (id: RvqPedalId) => {
    if (rvqPedals[id].mode === 'hold') {
      updateRvqPedal(id, { active: false });
    }
  };

  const handleRvqManualChange = (key: RvqKey, value: number) => {
    if (rvqPedalBaseRef.current) {
      rvqPedalBaseRef.current = { ...rvqPedalBaseRef.current, [key]: value };
      applyRvqPedalLayer(rvqPedals);
    } else {
      sendFxChange(key, value);
    }
  };

  const clearRvqControls = () => {
    rvqPedalBaseRef.current = null;
    const next = cloneRvqPedals(rvqPedals);
    RVQ_PEDAL_DEFS.forEach((pedal) => {
      next[pedal.id].active = false;
    });
    setRvqPedals(next);
    sendRvqValues(RVQ_KEYS.reduce((values, key) => {
      values[key] = 0;
      return values;
    }, {} as RvqValues));
  };

  const setPerformanceKey = (key: keyof PerformanceState, value: number) => {
    setPerformanceState((previous) => ({ ...previous, [key]: value }));
  };

  const setTextLabKey = (key: keyof TextLabState, value: number) => {
    setTextLabState((previous) => ({ ...previous, [key]: value }));
  };

  const resetTextLab = () => {
    setTextLabState(DEFAULT_TEXT_LAB_STATE);
  };

  const resetFx = () => {
    setAllRvqPedalsInactive(false);
    (Object.entries(DEFAULT_FX_STATE) as [keyof FxState, number][]).forEach(([key, value]) => {
      sendFxChange(key, value);
    });
  };

  const handleResetDefaults = () => {
    sendParamChange(0, DEFAULT_TEMPERATURE);       // temperature
    sendParamChange(1, DEFAULT_TOPK);              // topk
    sendParamChange(3, COLLIDER_CFG_MUSICCOCA);    // cfgmusiccoca (Collider override)
    sendParamChange(4, COLLIDER_CFG_NOTES);        // cfgnotes (Collider default)
    sendParamChange(48, DEFAULT_CFG_DRUMS);        // cfgdrums
    sendParamChange(7, DEFAULT_UNMASK_WIDTH);      // unmaskwidth
    sendParamChange(8, CONFABULATOR_DEFAULT_BUFFER_SIZE); // buffersize, 4096 samples / ~85 ms
    sendParamChange(39, DEFAULT_DRUMLESS ? 1 : 0); // drumless
    sendParamChange(47, 0);                        // seed rotation
    PCA_PARAM_ADDRESSES.forEach((address) => sendParamChange(address, 0));
    setPerformanceState(DEFAULT_PERFORMANCE_STATE);
    setTextLabState(DEFAULT_TEXT_LAB_STATE);
    resetFx();
  };

  const resetModel = () => {
    sendParamChange(31, 1.0);
    setTimeout(() => sendParamChange(31, 0.0), 100);
  };

  const kickGeneration = (delayMs = 0) => {
    const pulse = () => {
      sendParamChange(31, 1.0);
      setTimeout(() => sendParamChange(31, 0.0), 100);
    };
    if (delayMs > 0) {
      setTimeout(pulse, delayMs);
    } else {
      pulse();
    }
  };

  const sendPcaShape = (values: number[]) => {
    PCA_PARAM_ADDRESSES.forEach((address, index) => {
      sendParamChange(address, values[index] ?? 0);
    });
  };

  const applyParamsState = (next: ParamsState) => {
    sendParamChange(0, next.temperature);
    sendParamChange(1, Math.round(next.topk));
    sendParamChange(3, next.cfgmusiccoca);
    sendParamChange(4, next.cfgnotes);
    sendParamChange(48, next.cfgdrums);
    sendParamChange(7, Math.round(next.unmaskwidth));
    sendParamChange(8, next.buffersize);
    sendParamChange(39, next.drumless ? 1 : 0);
    sendParamChange(47, Math.round(next.seedrotation));
    PCA_PARAM_ADDRESSES.forEach((address, index) => {
      const key = `pca_coeff_${index}` as keyof ParamsState;
      sendParamChange(address, Number(next[key] ?? 0));
    });
  };

  const applyFxState = (next: FxState) => {
    (Object.entries(next) as [keyof FxState, number][]).forEach(([key, value]) => {
      sendFxChange(key, value);
    });
  };

  const nextIdRef = useRef(3);
  const nextColorRef = useRef(3);
  /** Index into SHUFFLED_SUGGESTIONS — starts at 3 because the first 3 are used for initial prompts. */
  const deckIndexRef = useRef(3);


  // Refs for current state (used by updateState callback)
  const promptsRef = useRef(prompts);
  promptsRef.current = prompts;
  const listenerRef = useRef(listener);
  listenerRef.current = listener;
  const pendingTextEmbeddingRef = useRef<{ nodeId: number; slot: number; attempts: number } | null>(null);
  const pendingSourceEmbeddingRef = useRef<{ nodeId: number; slot: number; attempts: number; name: string; bankId: string } | null>(null);
  const rvqPedalBaseRef = useRef<RvqValues | null>(null);
  const recipeInputRef = useRef<HTMLInputElement>(null);
  const agentEventsRef = useRef<AgentEvent[]>([]);
  const agentCommandQueueRef = useRef<any[]>([]);
  const remoteModelsRequestedRef = useRef(false);

  const appendAgentEvent = useCallback((direction: AgentEvent['direction'], payload: unknown) => {
    const event: AgentEvent = {
      at: new Date().toISOString(),
      t: Math.round(window.performance.now()) / 1000,
      direction,
      payload,
    };
    agentEventsRef.current = [...agentEventsRef.current, event];
  }, []);

  // ─── Bridge: send prompts + weights to native ──────────────────────

  const sendPrompts = useCallback(() => {
    const weights = calculateWeights(listenerRef.current, promptsRef.current);
    // Build engine payload — audio prompt must be at index 0 (native hardcodes it there)
    const emptySlot = (): PromptPayload => ({ text: '', weight: 0, kind: 'text' });
    const payloadForPrompt = (p: ConfabulatorPromptNode, weight: number): PromptPayload => {
      const baseEmbedding = p.bankEmbedding
        ? driftEmbedding(p.bankEmbedding, `${p.bankId ?? p.id}:${p.label}`, performanceState)
        : p.textEmbedding;
      const embedding = baseEmbedding
        ? textLabEmbedding(baseEmbedding, `${p.bankId ?? 'text'}:${p.id}:${p.label}`, textLabState, selectedBankItem?.embedding)
        : undefined;
      return {
        text: p.label,
        weight,
        kind: p.isAudio ? 'audio' : (embedding ? 'bank' : 'text'),
        embedding,
      };
    };
    const data: PromptPayload[] = Array.from({ length: MAX_ENGINE_PROMPTS }, emptySlot);
    const audioIdx = promptsRef.current.findIndex(p => p.isAudio);
    if (audioIdx !== -1) {
      data[0] = payloadForPrompt(promptsRef.current[audioIdx], weights[audioIdx] ?? 0);
      let dest = 1;
      promptsRef.current.forEach((p, i) => {
        if (i !== audioIdx && dest < MAX_ENGINE_PROMPTS) {
          data[dest++] = payloadForPrompt(p, weights[i] ?? 0);
        }
      });
    } else {
      promptsRef.current.forEach((p, i) => {
        if (i < MAX_ENGINE_PROMPTS) {
          data[i] = payloadForPrompt(p, weights[i] ?? 0);
        }
      });
    }
    post({ type: 'textPrompts', value: data });
  }, [performanceState, selectedBankItem, textLabState]);

  // ─── Throttled prompt sending ─────────────────────────────────────
  // Decouple engine IPC from the 60fps animation loop. Position changes
  // from physics update refs instantly (so the visual is smooth), but we
  // only push weight updates to the native engine at ~10Hz — fast enough
  // for perceptible audio blending, slow enough to avoid flooding the
  // TFLite quantizer with redundant invocations.
  const sendThrottleRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastSendTimeRef = useRef(0);

  useEffect(() => {
    const THROTTLE_MS = 100; // ~10 Hz
    const now = Date.now();
    const elapsed = now - lastSendTimeRef.current;

    if (sendThrottleRef.current) {
      clearTimeout(sendThrottleRef.current);
      sendThrottleRef.current = null;
    }

    if (elapsed >= THROTTLE_MS) {
      sendPrompts();
      lastSendTimeRef.current = now;
    } else {
      // Trailing edge — guarantees the final position is always sent
      sendThrottleRef.current = setTimeout(() => {
        sendPrompts();
        lastSendTimeRef.current = Date.now();
        sendThrottleRef.current = null;
      }, THROTTLE_MS - elapsed);
    }
  }, [prompts, listener, sendPrompts]);

  // Clean up trailing-edge timer on unmount
  useEffect(() => () => {
    if (sendThrottleRef.current) clearTimeout(sendThrottleRef.current);
  }, []);

  useEffect(() => {
    if (performanceState.drift <= 0.0001 && performanceState.snapback <= 0.0001 && textLabState.scan <= 0.0001) return;
    const timer = window.setInterval(() => {
      if (promptsRef.current.some((prompt) => prompt.bankEmbedding || prompt.textEmbedding)) {
        sendPrompts();
        lastSendTimeRef.current = Date.now();
      }
    }, 240);
    return () => window.clearInterval(timer);
  }, [performanceState.drift, performanceState.snapback, textLabState.scan, sendPrompts]);

  // ─── Bridge: lifecycle ─────────────────────────────────────────────
  useEffect(() => {
    window.updateState = (state: any) => {
      // When model loads, re-send our prompts so the engine uses the prompt surface
      if (state.modelName) {
        setModelName(state.modelName);
        sendPrompts();
      }
      if (state.isPlaying !== undefined) {
        setIsPlaying(state.isPlaying);
      }
      if (state.audioLevel !== undefined) {
        setAudioLevel(state.audioLevel);
      }
      if (state.localModels !== undefined) {
        setLocalModels(state.localModels);
      }
      if (state.remoteModels !== undefined) {
        setRemoteModels(state.remoteModels);
        setIsFetchingModels(false);
      }
      if (state.remoteModelsError !== undefined) {
        setIsFetchingModels(false);
      }
      if (state.downloadProgress !== undefined) {
        setDownloadProgress(state.downloadProgress);
      }
      if (state.downloadPath !== undefined) {
        setDownloadPath(state.downloadPath);
      }
      if (state.resourcesMissing !== undefined) {
        setResourcesMissing(state.resourcesMissing);
      }
      if (state.resourcesProgress !== undefined) {
        setResourcesProgress(state.resourcesProgress);
      }

      if (state.metrics !== undefined) {
        setMetrics(m => ({ ...m, ...state.metrics }));
      }
      if (state.recorder !== undefined) {
        setRecorderState(previous => ({ ...previous, ...state.recorder }));
      }
      if (state.agent !== undefined) {
        setAgentStatus(previous => ({ ...previous, ...state.agent }));
      }
      if (state.agentCommand !== undefined) {
        const queuedCommand = {
          ...state.agentCommand,
          __receivedAt: Date.now(),
        };
        setAgentStatus(previous => ({
          ...previous,
          lastCommand: typeof state.agentCommand.type === 'string' ? state.agentCommand.type : 'command',
        }));
        setAgentCommand(queuedCommand);
        agentCommandQueueRef.current.push(queuedCommand);
        setAgentCommandPulse(pulse => pulse + 1);
      }
      if (state.params !== undefined) {
        setParamsState(p => {
          const next = { ...p };
          if (state.params.temperature !== undefined) next.temperature = state.params.temperature;
          if (state.params.topk !== undefined) next.topk = state.params.topk;
          if (state.params.cfgnotes !== undefined) next.cfgnotes = state.params.cfgnotes;
          if (state.params.cfgmusiccoca !== undefined) next.cfgmusiccoca = state.params.cfgmusiccoca;
          if (state.params.cfgdrums !== undefined) next.cfgdrums = state.params.cfgdrums;
          if (state.params.unmaskwidth !== undefined) next.unmaskwidth = state.params.unmaskwidth;
          if (state.params.buffersize !== undefined) next.buffersize = state.params.buffersize;
          if (state.params.volume !== undefined) next.volume = state.params.volume;
          if (state.params.drumless !== undefined) next.drumless = state.params.drumless;
          if (state.params.seedrotation !== undefined) next.seedrotation = state.params.seedrotation;
          if (state.params.pca_coeff_0 !== undefined) next.pca_coeff_0 = state.params.pca_coeff_0;
          if (state.params.pca_coeff_1 !== undefined) next.pca_coeff_1 = state.params.pca_coeff_1;
          if (state.params.pca_coeff_2 !== undefined) next.pca_coeff_2 = state.params.pca_coeff_2;
          if (state.params.pca_coeff_3 !== undefined) next.pca_coeff_3 = state.params.pca_coeff_3;
          if (state.params.pca_coeff_4 !== undefined) next.pca_coeff_4 = state.params.pca_coeff_4;
          if (state.params.pca_coeff_5 !== undefined) next.pca_coeff_5 = state.params.pca_coeff_5;
          return next;
        });
      }
      if (state.fx !== undefined) {
        setFxState((previous) => ({ ...previous, ...state.fx }));
      }
      if (state.promptEmbedding !== undefined) {
        const nodeId = Number(state.promptEmbedding.nodeId);
        const embedding = Array.isArray(state.promptEmbedding.embedding)
          ? state.promptEmbedding.embedding.map((value: unknown) => Number(value))
          : [];
        if (Number.isFinite(nodeId) && embedding.length === TEXT_EMBEDDING_DIM && embedding.every(Number.isFinite)) {
          const sourcePending = pendingSourceEmbeddingRef.current;
          if (sourcePending && sourcePending.nodeId === nodeId) {
            const sourceItem: ConfabulatorBankItem = {
              id: sourcePending.bankId,
              label: sourcePending.name,
              bank: SOURCE_BANK_ID,
              styleTokens: [],
              embedding,
            };
            pendingSourceEmbeddingRef.current = null;
            setSourceStatus('EMBED');
            setSourceName(sourcePending.name);
            setSourceBankItems(prev => [sourceItem, ...prev.filter((item) => item.id !== sourceItem.id)].slice(0, MAX_SOURCE_BANK_ITEMS));
            setSelectedBankSetId(SOURCE_BANK_ID);
            setSelectedBankId(sourceItem.id);
            setPrompts(prev => prev.map(p => p.id === nodeId ? {
              ...p,
              label: sourcePending.name.slice(0, 96),
              isAudio: false,
              isBank: true,
              bankId: sourcePending.bankId,
              bankEmbedding: embedding,
              textEmbedding: undefined,
            } : p));
            window.setTimeout(sendPrompts, 0);
            return;
          }
          pendingTextEmbeddingRef.current = null;
          setTextLabStatus('VEC');
          setTextLabState((previous) => isTextLabNeutral(previous)
            ? { ...previous, warp: 0.24, scramble: 0.06, scan: 0.12, gravity: 0.5 }
            : previous);
          setPrompts(prev => prev.map(p => p.id === nodeId ? {
            ...p,
            isAudio: false,
            isBank: false,
            bankId: undefined,
            bankEmbedding: undefined,
            textEmbedding: embedding,
          } : p));
        }
      }
      if (state.promptEmbeddingError !== undefined) {
        const nodeId = Number(state.promptEmbeddingError.nodeId);
        const sourcePending = pendingSourceEmbeddingRef.current;
        if (sourcePending && sourcePending.nodeId === nodeId) {
          if (sourcePending.attempts < 30) {
            sourcePending.attempts += 1;
            setSourceStatus('LOAD');
            window.setTimeout(() => {
              post({ type: 'requestPromptEmbedding', nodeId: sourcePending.nodeId, index: sourcePending.slot });
            }, 220);
          } else {
            pendingSourceEmbeddingRef.current = null;
            setSourceStatus('ERR');
          }
          return;
        }
        const pending = pendingTextEmbeddingRef.current;
        if (pending && pending.attempts < 12) {
          pending.attempts += 1;
          setTextLabStatus('ENC');
          window.setTimeout(() => {
            post({ type: 'requestPromptEmbedding', nodeId: pending.nodeId, index: pending.slot });
          }, 180);
        } else {
          pendingTextEmbeddingRef.current = null;
          setTextLabStatus('WAIT');
        }
      }
      if (state.openSettings !== undefined) {
        setIsSettingsOpen(!!state.openSettings);
      }
      // Audio prompt loaded from native file picker
      if (state.isAudioPrompt && state.prompt) {
        const name = String(state.prompt);
        const existingAudio = promptsRef.current.find((p) => p.isAudio);
        const nodeId = existingAudio?.id ?? nextIdRef.current++;
        pendingSourceEmbeddingRef.current = {
          nodeId,
          slot: 0,
          attempts: 0,
          name,
          bankId: `source:${Date.now()}:${hashString(name)}`,
        };
        setSourceName(name);
        setSourceStatus('LOAD');
        setSelectedBallId(nodeId);
        setPrompts(prev => {
          const existing = prev.findIndex(p => p.isAudio);
          if (existing !== -1) {
            return prev.map((p, i) => i === existing ? { ...p, label: name } : p);
          }
          const el = promptSurfaceRef.current;
          const w = el ? el.getBoundingClientRect().width : 800;
          const h = el ? el.getBoundingClientRect().height : 600;
          const pad = 60;
          return [...prev, {
            id: nodeId,
            x: pad + Math.random() * (w - pad * 2),
            y: pad + Math.random() * (h - pad * 2),
            label: name,
            colorIndex: nextColorRef.current++,
            isAudio: true,
          }];
        });
        window.setTimeout(() => {
          post({ type: 'requestPromptEmbedding', nodeId, index: 0 });
        }, 220);
      } else if (state.isAudioPrompt === false) {
        pendingSourceEmbeddingRef.current = null;
      }
    };

    post({ type: 'uiReady' });
    if (!remoteModelsRequestedRef.current) {
      remoteModelsRequestedRef.current = true;
      post({ type: 'listRemoteModels' });
    }

    return () => {
      delete (window as any).updateState;
    };
  }, [sendPrompts]);

  // ─── UI callbacks ─────────────────────────────────────────────────

  const openSettings = () => {
    post({ type: 'openSettings' });
  };

  const togglePlay = () => {
    post({ type: 'togglePlay' });
  };

  const handlePromptMove = useCallback((id: number, x: number, y: number) => {
    setPrompts(prev => prev.map(p => p.id === id ? { ...p, x, y } : p));
  }, []);

  const handleListenerMove = useCallback((x: number, y: number) => {
    setListener({ x, y });
  }, []);

  const handleBallSelect = useCallback((id: number | null) => {
    setSelectedBallId(id);
    if (id === null) return;
    const prompt = promptsRef.current.find((p) => p.id === id);
    if (!prompt?.bankId) return;
    const owningBank = bankSets.find((bank) =>
      bank.items.some((item) => item.id === prompt.bankId)
    );
    if (owningBank) {
      setSelectedBankSetId(owningBank.id);
      setSelectedBankId(prompt.bankId);
    }
  }, [bankSets]);

  const requestSelectedTextEmbedding = useCallback(() => {
    if (selectedBallId === null) {
      setTextLabStatus('TEXT');
      return;
    }
    const prompt = promptsRef.current.find((p) => p.id === selectedBallId);
    if (!prompt || prompt.isAudio || prompt.isBank || prompt.label.trim().length === 0) {
      setTextLabStatus('TEXT');
      return;
    }
    const slot = engineSlotForPrompt(promptsRef.current, selectedBallId);
    if (slot < 0) {
      setTextLabStatus('SLOT');
      return;
    }

    pendingTextEmbeddingRef.current = { nodeId: selectedBallId, slot, attempts: 0 };
    setTextLabStatus('ENC');
    sendPrompts();
    window.setTimeout(() => {
      post({ type: 'requestPromptEmbedding', nodeId: selectedBallId, index: slot });
    }, 160);
  }, [selectedBallId, sendPrompts]);

  const releaseSelectedTextEmbedding = useCallback(() => {
    if (selectedBallId === null) return;
    pendingTextEmbeddingRef.current = null;
    setTextLabStatus('RAW');
    setPrompts(prev => prev.map(p => p.id === selectedBallId ? {
      ...p,
      textEmbedding: undefined,
    } : p));
  }, [selectedBallId]);

  const requestSourceEmbedding = useCallback(() => {
    pendingSourceEmbeddingRef.current = null;
    setSourceStatus('LOAD');
    setSourceName('AUDIO');
    post({ type: 'loadAudioPrompt' });
  }, []);

  const handlePromptAdd = useCallback((x: number, y: number) => {
    const id = nextIdRef.current++;
    const colorIndex = nextColorRef.current++;
    // When the deck runs out, reshuffle and reset the index
    if (deckIndexRef.current >= SHUFFLED_SUGGESTIONS.length) {
      shuffle(SHUFFLED_SUGGESTIONS);
      deckIndexRef.current = 0;
    }
    const label = SHUFFLED_SUGGESTIONS[deckIndexRef.current++];
    setPrompts(prev => [...prev, { id, x, y, label, colorIndex }]);
  }, []);

  const bankLabel = useCallback((item: ConfabulatorBankItem) => {
    return displayBankLabel(item);
  }, []);

  const bankPromptPatch = useCallback((item: ConfabulatorBankItem) => ({
    label: bankLabel(item),
    isAudio: false,
    isBank: true,
    bankId: item.id,
    bankEmbedding: item.embedding,
    textEmbedding: undefined,
  }), [bankLabel]);

  const setBankControlsToItem = useCallback((item: ConfabulatorBankItem) => {
    const bankId = bankSets.find((bank) => bank.items.some((bankItem) => bankItem.id === item.id))?.id;
    if (bankId) {
      setSelectedBankSetId(bankId);
    }
    setSelectedBankId(item.id);
  }, [bankSets]);

  const addBankPrompt = useCallback((item?: ConfabulatorBankItem) => {
    const chosen = item
      ?? activeBankItems.find((bankItem) => bankItem.id === selectedBankId)
      ?? activeBankItems[0]
      ?? bankSets[0]?.items[0];
    if (!chosen) return;
    const el = promptSurfaceRef.current;
    const w = el ? el.getBoundingClientRect().width : 800;
    const h = el ? el.getBoundingClientRect().height : 600;
    const pad = 68;
    const node: ConfabulatorPromptNode = {
      id: nextIdRef.current++,
      x: pad + Math.random() * Math.max(1, w - pad * 2),
      y: pad + Math.random() * Math.max(1, h - pad * 2),
      colorIndex: nextColorRef.current++,
      ...bankPromptPatch(chosen),
    };
    setPrompts(prev => {
      const kept = prev.length >= MAX_ENGINE_PROMPTS ? prev.slice(0, MAX_ENGINE_PROMPTS - 1) : prev;
      return [...kept, node];
    });
    setSelectedBallId(node.id);
    setBankControlsToItem(chosen);
  }, [activeBankItems, bankPromptPatch, bankSets, selectedBankId, setBankControlsToItem]);

  const applyBankToSelected = useCallback((item?: ConfabulatorBankItem) => {
    const chosen = item
      ?? activeBankItems.find((bankItem) => bankItem.id === selectedBankId)
      ?? activeBankItems[0]
      ?? bankSets[0]?.items[0];
    if (!chosen || selectedBallId === null) return false;
    const existing = promptsRef.current.find((p) => p.id === selectedBallId);
    if (existing?.isAudio) {
      post({ type: 'clearAudioPrompt' });
    }
    setPrompts(prev => prev.map(p => p.id === selectedBallId ? {
      ...p,
      ...bankPromptPatch(chosen),
    } : p));
    setBankControlsToItem(chosen);
    return true;
  }, [activeBankItems, bankPromptPatch, bankSets, selectedBallId, selectedBankId, setBankControlsToItem]);

  const handleBankItemChange = useCallback((id: string) => {
    setSelectedBankId(id);
    const item = activeBankItems.find((bankItem) => bankItem.id === id);
    if (item && selectedBallId !== null) {
      applyBankToSelected(item);
    }
  }, [activeBankItems, applyBankToSelected, selectedBallId]);

  const handleBankSetChange = useCallback((id: string) => {
    setSelectedBankSetId(id);
    const bank = bankSets.find((entry) => entry.id === id);
    const firstItem = bank?.items[0];
    setSelectedBankId(firstItem?.id ?? '');
    if (firstItem && selectedBallId !== null) {
      applyBankToSelected(firstItem);
    }
  }, [applyBankToSelected, bankSets, selectedBallId]);

  const addRandomBankPrompt = useCallback(() => {
    const item = randomBankItem(activeBankItems);
    if (item) {
      addBankPrompt(item);
    }
  }, [activeBankItems, addBankPrompt]);

  const rerollInterfaceEmbeddings = useCallback(() => {
    const isEditablePrompt = (prompt: ConfabulatorPromptNode) =>
      !prompt.isAudio && prompt.label.trim().toLowerCase() !== PCA_NODE_LABEL;
    let didReroll = false;
    let firstPromptId: number | null = null;
    let firstItem: ConfabulatorBankItem | undefined;
    const itemPool = shuffle([...allBankItems]);
    let itemPoolIndex = 0;

    flushSync(() => setPrompts(prev => {
      const updated = prev.map((prompt) => {
        if (!isEditablePrompt(prompt)) return prompt;
        const item = itemPool[itemPoolIndex++] ?? randomBankItem();
        if (!item) return prompt;
        didReroll = true;
        if (!firstItem) {
          firstItem = item;
          firstPromptId = prompt.id;
        }
        return { ...prompt, ...bankPromptPatch(item) };
      });
      return didReroll ? updated : prev;
    }));

    if (!didReroll) {
      addRandomBankPrompt();
      return false;
    }
    if (firstItem) {
      setBankControlsToItem(firstItem);
    }
    if (firstPromptId !== null) {
      setSelectedBallId(firstPromptId);
    }
    window.setTimeout(sendPrompts, 0);
    return true;
  }, [addRandomBankPrompt, allBankItems, bankPromptPatch, sendPrompts, setBankControlsToItem]);

  const rerollSelectedOrAddBankPrompt = useCallback(() => {
    const current = promptsRef.current;
    const selected = selectedBallId !== null ? current.find((prompt) => prompt.id === selectedBallId) : undefined;
    const isEditableSelected = selected && !selected.isAudio && selected.label.trim().toLowerCase() !== PCA_NODE_LABEL;
    if (!isEditableSelected) {
      addRandomBankPrompt();
      return;
    }
    const item = randomBankItem(allBankItems);
    if (!item) return;
    setPrompts(prev => prev.map((prompt) => prompt.id === selected.id ? {
      ...prompt,
      ...bankPromptPatch(item),
    } : prompt));
    setBankControlsToItem(item);
  }, [addRandomBankPrompt, allBankItems, bankPromptPatch, selectedBallId, setBankControlsToItem]);

  const addPcaPrompt = useCallback((selectNode = true) => {
    const el = promptSurfaceRef.current;
    const w = el ? el.getBoundingClientRect().width : 800;
    const h = el ? el.getBoundingClientRect().height : 600;
    setPrompts(prev => {
      const existing = prev.findIndex(p => p.label.trim().toLowerCase() === PCA_NODE_LABEL);
      if (existing !== -1) {
        if (selectNode) {
          setSelectedBallId(prev[existing].id);
        }
        return prev;
      }
      const node = {
        id: nextIdRef.current++,
        x: w * 0.5,
        y: h * 0.5,
        label: PCA_NODE_LABEL,
        colorIndex: nextColorRef.current++,
      };
      if (selectNode) {
        setSelectedBallId(node.id);
      }
      return [...prev, node];
    });
  }, []);

  const saveSettingsBank = useCallback(() => {
    const now = Date.now();
    const promptsSnapshot: SavedSettingsPrompt[] = promptsRef.current.map((prompt) => ({
      id: prompt.id,
      x: prompt.x,
      y: prompt.y,
      label: prompt.label,
      colorIndex: prompt.colorIndex,
      isAudio: prompt.isAudio,
      isBank: prompt.isBank,
      bankId: prompt.bankId,
      bankEmbedding: prompt.bankEmbedding?.length === TEXT_EMBEDDING_DIM ? prompt.bankEmbedding : undefined,
      textEmbedding: prompt.textEmbedding?.length === TEXT_EMBEDDING_DIM ? prompt.textEmbedding : undefined,
    }));
    const bankNumber = Math.min(settingsBanks.length + 1, MAX_SETTINGS_BANKS);
    const snapshot: SavedSettingsBank = {
      id: `settings-${now}`,
      name: `BANK ${String(bankNumber).padStart(2, '0')} ${new Date(now).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`,
      savedAt: now,
      params: { ...paramsState },
      fx: { ...fxState },
      performance: { ...performanceState },
      textLab: { ...textLabState },
      rvqPedals: cloneRvqPedals(rvqPedals),
      prompts: promptsSnapshot,
      listener: { ...listenerRef.current },
      selectedBallId,
      selectedBankSetId,
      selectedBankId,
      sliderPos,
      collisionsEnabled,
    };
    setSettingsBanks(prev => [snapshot, ...prev].slice(0, MAX_SETTINGS_BANKS));
    setSelectedSettingsBankId(snapshot.id);
  }, [collisionsEnabled, fxState, paramsState, performanceState, promptsRef, rvqPedals, selectedBallId, selectedBankId, selectedBankSetId, settingsBanks.length, sliderPos, textLabState]);

  const loadSettingsBank = useCallback((bankId = selectedSettingsBankId) => {
    const bank = settingsBanks.find((entry) => entry.id === bankId);
    if (!bank) return;
    const hydratedPrompts: ConfabulatorPromptNode[] = bank.prompts.map((prompt) => {
      const item = prompt.bankId ? allBankItems.find((bankItem) => bankItem.id === prompt.bankId) : undefined;
      const savedEmbedding = prompt.bankEmbedding?.length === TEXT_EMBEDDING_DIM ? prompt.bankEmbedding : undefined;
      const bankEmbedding = item?.embedding ?? savedEmbedding;
      return {
        ...prompt,
        isAudio: prompt.isAudio,
        isBank: prompt.isBank && !!bankEmbedding,
        bankId: item || savedEmbedding ? prompt.bankId : undefined,
        bankEmbedding,
        textEmbedding: prompt.textEmbedding?.length === TEXT_EMBEDDING_DIM ? prompt.textEmbedding : undefined,
      };
    });
    setPrompts(hydratedPrompts);
    setListener(bank.listener);
    setSelectedBallId(bank.selectedBallId);
    setSelectedBankSetId(bank.selectedBankSetId);
    setSelectedBankId(bank.selectedBankId);
    setSliderPos(bank.sliderPos);
    setCollisionsEnabled(bank.collisionsEnabled);
    applyParamsState(bank.params);
    applyFxState(bank.fx);
    rvqPedalBaseRef.current = null;
    setRvqPedals(cloneRvqPedals(bank.rvqPedals ?? createDefaultRvqPedals()));
    setPerformanceState(bank.performance);
    setTextLabState(bank.textLab);
    setTextLabStatus(hydratedPrompts.some((prompt) => prompt.id === bank.selectedBallId && prompt.textEmbedding) ? 'VEC' : 'RAW');
    nextIdRef.current = Math.max(3, ...hydratedPrompts.map((prompt) => prompt.id + 1));
    nextColorRef.current = Math.max(3, ...hydratedPrompts.map((prompt) => prompt.colorIndex + 1));
    window.setTimeout(() => {
      sendPrompts();
      kickGeneration();
    }, 180);
  }, [allBankItems, applyFxState, applyParamsState, kickGeneration, selectedSettingsBankId, sendPrompts, settingsBanks]);

  const deleteSettingsBank = useCallback(() => {
    if (!selectedSettingsBankId) return;
    setSettingsBanks(prev => prev.filter((bank) => bank.id !== selectedSettingsBankId));
    setSelectedSettingsBankId('');
  }, [selectedSettingsBankId]);

  const applyMacro = useCallback((name: 'metal' | 'melt' | 'shred' | 'ghost') => {
    addPcaPrompt();
    setAllRvqPedalsInactive(false);
    if (name === 'metal') {
      sendParamChange(0, 1.15);
      sendParamChange(1, 88);
      sendParamChange(3, 2.25);
      sendPcaShape([0.72, -0.2, 0.34, 0.05, -0.12, 0.18]);
      sendFxChange('wet', 0.82);
      sendFxChange('drive', 0.36);
      sendFxChange('fold', 0.28);
      sendFxChange('crush', 0.16);
      sendFxChange('ring', 0.52);
      sendFxChange('comb', 0.74);
      sendFxChange('body', 0.86);
      sendFxChange('smear', 0.12);
      sendFxChange('stutter', 0.08);
      sendFxChange('pitch', 0.58);
      sendFxChange('harmonics', 0.82);
      sendFxChange('noise', 0.02);
      sendFxChange('rvqForce', 0.28);
      sendFxChange('rvqBreathe', 0.34);
      sendFxChange('rvqMemory', 0.08);
      sendFxChange('rvqCoarse', 0.18);
      sendFxChange('rvqFine', 0.08);
      sendFxChange('rvqSweep', 0.12);
      sendFxChange('rvqHold', 0.18);
      sendFxChange('rvqInvert', 0.04);
      sendFxChange('rvqJitter', 0.08);
      sendFxChange('rvqStride', 0.22);
      setPerformanceState({ drift: 0.22, snapback: 0.62 });
      setTextLabState({ warp: 0.42, scramble: 0.1, morph: 0.18, oppose: 0.04, scan: 0.12, gravity: 0.52 });
    } else if (name === 'melt') {
      sendParamChange(0, 1.55);
      sendParamChange(1, 160);
      sendParamChange(3, 3.1);
      sendPcaShape([-0.48, 0.86, 0.28, -0.32, 0.2, -0.1]);
      sendFxChange('wet', 0.76);
      sendFxChange('drive', 0.18);
      sendFxChange('fold', 0.18);
      sendFxChange('crush', 0.04);
      sendFxChange('ring', 0.08);
      sendFxChange('comb', 0.22);
      sendFxChange('body', 0.44);
      sendFxChange('smear', 0.86);
      sendFxChange('stutter', 0.18);
      sendFxChange('pitch', 0.36);
      sendFxChange('harmonics', 0.42);
      sendFxChange('noise', 0.04);
      sendFxChange('rvqForce', 0.48);
      sendFxChange('rvqBreathe', 0.46);
      sendFxChange('rvqMemory', 0.24);
      sendFxChange('rvqCoarse', 0.26);
      sendFxChange('rvqFine', 0.42);
      sendFxChange('rvqSweep', 0.24);
      sendFxChange('rvqHold', 0.08);
      sendFxChange('rvqInvert', 0.18);
      sendFxChange('rvqJitter', 0.36);
      sendFxChange('rvqStride', 0.28);
      setPerformanceState({ drift: 0.68, snapback: 0.18 });
      setTextLabState({ warp: 0.28, scramble: 0.26, morph: 0.42, oppose: 0.12, scan: 0.38, gravity: 0.26 });
    } else if (name === 'shred') {
      sendParamChange(0, 2.65);
      sendParamChange(1, 720);
      sendParamChange(3, 2.35);
      sendParamChange(4, 0.62);
      sendParamChange(7, 112);
      sendParamChange(48, 2.25);
      sendParamChange(47, Math.round(Math.random() * 1000));
      sendPcaShape([1.9, -1.45, 1.25, -1.08, 0.86, -0.64]);
      sendFxChange('wet', 0.74);
      sendFxChange('drive', 0.64);
      sendFxChange('fold', 0.68);
      sendFxChange('crush', 0.32);
      sendFxChange('ring', 0.52);
      sendFxChange('comb', 0.36);
      sendFxChange('body', 0.22);
      sendFxChange('smear', 0.26);
      sendFxChange('stutter', 0.44);
      sendFxChange('pitch', Math.random() > 0.5 ? 0.18 : 0.86);
      sendFxChange('harmonics', 0.92);
      sendFxChange('noise', 0.025);
      sendFxChange('rvqForce', 0.92);
      sendFxChange('rvqBreathe', 0.22);
      sendFxChange('rvqMemory', 0.58);
      sendFxChange('rvqCoarse', 0.88);
      sendFxChange('rvqFine', 0.92);
      sendFxChange('rvqSweep', 0.68);
      sendFxChange('rvqHold', 0.12);
      sendFxChange('rvqInvert', 0.76);
      sendFxChange('rvqJitter', 0.82);
      sendFxChange('rvqStride', 0.74);
      setPerformanceState({ drift: 0.86, snapback: 0.05 });
      setTextLabState({ warp: 0.92, scramble: 0.82, morph: 0.08, oppose: 0.66, scan: 0.58, gravity: 0.08 });
      kickGeneration(140);
    } else {
      sendParamChange(0, 0.92);
      sendParamChange(1, 48);
      sendParamChange(3, 3.7);
      sendPcaShape([-0.18, 0.54, -0.7, 0.42, -0.16, 0.12]);
      sendFxChange('wet', 0.52);
      sendFxChange('drive', 0.06);
      sendFxChange('fold', 0.04);
      sendFxChange('crush', 0.02);
      sendFxChange('ring', 0.03);
      sendFxChange('comb', 0.34);
      sendFxChange('body', 0.64);
      sendFxChange('smear', 0.72);
      sendFxChange('stutter', 0.05);
      sendFxChange('pitch', 0.5);
      sendFxChange('harmonics', 0.18);
      sendFxChange('noise', 0.015);
      sendFxChange('rvqForce', 0.18);
      sendFxChange('rvqBreathe', 0.76);
      sendFxChange('rvqMemory', 0.44);
      sendFxChange('rvqCoarse', 0.06);
      sendFxChange('rvqFine', 0.18);
      sendFxChange('rvqSweep', 0.04);
      sendFxChange('rvqHold', 0.56);
      sendFxChange('rvqInvert', 0.02);
      sendFxChange('rvqJitter', 0.05);
      sendFxChange('rvqStride', 0.08);
      setPerformanceState({ drift: 0.18, snapback: 0.92 });
      setTextLabState({ warp: 0.12, scramble: 0.04, morph: 0.2, oppose: 0.02, scan: 0.08, gravity: 0.82 });
    }
  }, [addPcaPrompt]);

  const randomizeConfabulator = useCallback(() => {
    const rvqAmount = Math.random() > 0.42 ? 0.08 + Math.random() * 0.48 : 0;
    setAllRvqPedalsInactive(false);
    sendParamChange(0, 0.65 + Math.random() * 1.35);
    sendParamChange(1, Math.round(12 + Math.random() * 420));
    sendParamChange(3, 1.2 + Math.random() * 3.8);
    sendParamChange(7, Math.round(Math.random() * 28));
    sendParamChange(39, paramsState.drumless ? 1 : 0);
    sendParamChange(47, Math.round(Math.random() * 1000));
    PCA_PARAM_ADDRESSES.forEach((address) => {
      sendParamChange(address, (Math.random() * 2 - 1) * 1.75);
    });
    sendFxChange('rvqForce', rvqAmount);
    sendFxChange('rvqBreathe', Math.random());
    sendFxChange('rvqMemory', rvqAmount > 0 ? Math.random() : 0);
    sendFxChange('rvqCoarse', rvqAmount * Math.random());
    sendFxChange('rvqFine', rvqAmount * Math.random());
    sendFxChange('rvqSweep', rvqAmount * Math.random());
    sendFxChange('rvqHold', Math.random() * 0.82);
    sendFxChange('rvqInvert', rvqAmount * Math.random());
    sendFxChange('rvqJitter', rvqAmount * Math.random());
    sendFxChange('rvqStride', rvqAmount * Math.random());
    setPerformanceState({
      drift: Math.random(),
      snapback: Math.random() * 0.8,
    });
    setTextLabState({
      warp: Math.random(),
      scramble: Math.random() * Math.random(),
      morph: Math.random() * 0.72,
      oppose: Math.random() * 0.82,
      scan: Math.random() * Math.random(),
      gravity: Math.random() * 0.65,
    });
    addPcaPrompt(false);
    rerollInterfaceEmbeddings();
  }, [addPcaPrompt, paramsState.drumless, rerollInterfaceEmbeddings]);

  const randomizeDamage = useCallback(() => {
    sendFxChange('wet', 0.45 + Math.random() * 0.55);
    sendFxChange('drive', Math.random());
    sendFxChange('fold', Math.random());
    sendFxChange('crush', Math.random() * 0.82);
    sendFxChange('ring', Math.random());
    sendFxChange('comb', Math.random() * Math.random());
    sendFxChange('body', Math.random() * Math.random());
    sendFxChange('smear', Math.random());
    sendFxChange('stutter', Math.random());
    sendFxChange('pitch', Math.random());
    sendFxChange('harmonics', Math.random());
    sendFxChange('noise', Math.random() * 0.06);
  }, []);

  const joltConfabulator = useCallback(() => {
    const rvqAmount = 0.18 + Math.random() * 0.46;
    setAllRvqPedalsInactive(false);
    sendParamChange(47, Math.round(Math.random() * 1000));
    sendParamChange(0, 0.9 + Math.random() * 1.1);
    sendParamChange(1, Math.round(32 + Math.random() * 420));
    sendParamChange(3, 1.4 + Math.random() * 2.6);
    sendFxChange('rvqForce', rvqAmount);
    sendFxChange('rvqBreathe', 0.2 + Math.random() * 0.65);
    sendFxChange('rvqMemory', Math.random() * 0.62);
    sendFxChange('rvqCoarse', rvqAmount * Math.random());
    sendFxChange('rvqFine', rvqAmount * Math.random());
    sendFxChange('rvqSweep', Math.random() * 0.74);
    sendFxChange('rvqHold', Math.random() * 0.52);
    sendFxChange('rvqInvert', rvqAmount * Math.random());
    sendFxChange('rvqJitter', 0.08 + Math.random() * 0.62);
    sendFxChange('rvqStride', Math.random() * 0.72);
    setPerformanceState({
      drift: 0.18 + Math.random() * 0.72,
      snapback: Math.random() * 0.55,
    });
    setTextLabState((previous) => ({
      ...previous,
      warp: Math.min(1, previous.warp + 0.12 + Math.random() * 0.24),
      scramble: Math.min(1, previous.scramble + Math.random() * 0.34),
      scan: Math.min(1, previous.scan + Math.random() * 0.28),
      gravity: Math.max(0, previous.gravity - Math.random() * 0.2),
    }));
    addPcaPrompt();
  }, [addPcaPrompt]);

  const cleanConfabulator = useCallback(() => {
    handleResetDefaults();
    sendParamChange(0, 0.9);
    sendParamChange(1, 60);
    sendParamChange(3, COLLIDER_CFG_MUSICCOCA);
    sendParamChange(7, DEFAULT_UNMASK_WIDTH);
    setPerformanceState(DEFAULT_PERFORMANCE_STATE);
    setTextLabState(DEFAULT_TEXT_LAB_STATE);
    resetFx();
  }, []);

  const handleTextChange = useCallback((id: number, text: string) => {
    setPrompts(prev => prev.map(p => p.id === id ? {
      ...p,
      label: text,
      isBank: false,
      bankId: undefined,
      bankEmbedding: undefined,
      textEmbedding: undefined,
    } : p));
  }, []);

  const handlePromptDelete = useCallback((id: number) => {
    // If deleting an audio prompt, clear it in the engine
    const deleted = promptsRef.current.find(p => p.id === id);
    if (deleted?.isAudio) {
      post({ type: 'clearAudioPrompt' });
    }
    setPrompts(prev => prev.filter(p => p.id !== id));
    setSelectedBallId(prev => prev === id ? null : prev);
  }, []);

  const handleFirstThrow = useCallback(() => setHasThrown(true), []);

  const buildPatchSnapshot = useCallback((eventType: string) => {
    const currentPrompts = promptsRef.current;
    const weights = calculateWeights(listenerRef.current, currentPrompts);
    const selectedSet = bankSets.find((bank) => bank.id === selectedBankSetId);
    const selectedItem = activeBankItems.find((item) => item.id === selectedBankId) ?? selectedBankItem;
    const rvqValues = readRvqValues();
    const damage = {
      wet: fxState.wet,
      drive: fxState.drive,
      fold: fxState.fold,
      crush: fxState.crush,
      ring: fxState.ring,
      comb: fxState.comb,
      body: fxState.body,
      smear: fxState.smear,
      stutter: fxState.stutter,
      pitch: fxState.pitch,
      harmonics: fxState.harmonics,
      noise: fxState.noise,
    };

    return {
      schema_version: 1,
      application: 'CONFABULATOR',
      event_type: eventType,
      captured_at: new Date().toISOString(),
      model: {
        name: modelName,
        temperature: paramsState.temperature,
        topk: paramsState.topk,
        prompt_cfg: paramsState.cfgmusiccoca,
        note_cfg: paramsState.cfgnotes,
        drums_cfg: paramsState.cfgdrums,
        unmask_width: paramsState.unmaskwidth,
        seed_rotation: paramsState.seedrotation,
        no_drums: paramsState.drumless,
        buffer_size: paramsState.buffersize,
        volume: paramsState.volume,
      },
      prompt_surface: {
        listener: { ...listenerRef.current },
        selectedBallId,
        sliderPos,
        collisionsEnabled,
        prompts: currentPrompts.map((prompt, index) => ({
          id: prompt.id,
          label: prompt.label,
          x: prompt.x,
          y: prompt.y,
          weight: weights[index] ?? 0,
          colorIndex: prompt.colorIndex,
          kind: prompt.isAudio ? 'audio' : (prompt.bankEmbedding ? 'embedding' : (prompt.textEmbedding ? 'text-vector' : 'text')),
          isBank: !!prompt.isBank,
          bankId: prompt.bankId,
          bankEmbedding: prompt.bankEmbedding,
          textEmbedding: prompt.textEmbedding,
        })),
      },
      embeddings: {
        selectedBankSetId,
        selectedBankSetLabel: selectedSet?.label,
        selectedBankId,
        selectedBankLabel: selectedItem ? bankLabel(selectedItem) : undefined,
        selectedBankEmbedding: selectedItem?.embedding,
        sourceBankItemCount: sourceBankItems.length,
        sourceBankItems: sourceBankItems.map((item) => ({
          id: item.id,
          label: item.label,
          bank: item.bank,
          styleTokens: item.styleTokens,
        })),
      },
      pca: {
        coefficients: [
          paramsState.pca_coeff_0,
          paramsState.pca_coeff_1,
          paramsState.pca_coeff_2,
          paramsState.pca_coeff_3,
          paramsState.pca_coeff_4,
          paramsState.pca_coeff_5,
        ],
      },
      text_encoder: {
        status: textLabStatusLabel,
        ...textLabState,
      },
      rvq: {
        values: rvqValues,
        pedals: cloneRvqPedals(rvqPedals),
      },
      damage,
      performance: { ...performanceState },
      recorder: { ...recorderState },
      agent_performance: {
        schema_version: 1,
        status: { ...agentStatus },
        event_count: agentEventsRef.current.length,
        events: agentEventsRef.current,
      },
    };
  }, [
    agentStatus,
    activeBankItems,
    bankLabel,
    bankSets,
    collisionsEnabled,
    fxState,
    modelName,
    paramsState,
    performanceState,
    recorderState,
    rvqPedals,
    selectedBallId,
    selectedBankId,
    selectedBankItem,
    selectedBankSetId,
    sliderPos,
    sourceBankItems,
    textLabState,
    textLabStatusLabel,
  ]);

  const requestRecorderWindow = useCallback((seconds: number) => {
    setRecorderState(previous => ({ ...previous, rollingSeconds: seconds, status: 'window' }));
    post({ type: 'recorderSetWindow', seconds });
  }, []);

  const captureRecorderWindow = useCallback((seconds: number, mode: string) => {
    setRecorderState(previous => ({ ...previous, status: 'saving', error: undefined }));
    post({
      type: 'recorderCaptureLast',
      seconds,
      mode,
      patch: toMessageSafeObject(buildPatchSnapshot(mode)),
    });
  }, [buildPatchSnapshot]);

  const toggleRetroRecorder = useCallback(() => {
    if (recorderState.recording) {
      setRecorderState(previous => ({ ...previous, status: 'saving', error: undefined }));
      post({
        type: 'recorderStop',
        patch: toMessageSafeObject(buildPatchSnapshot('retro-stop')),
      });
      return;
    }
    setRecorderState(previous => ({ ...previous, recording: true, recordingSeconds: previous.availableSeconds, status: 'recording' }));
    post({
      type: 'recorderStart',
      seconds: recorderState.rollingSeconds,
      patch: toMessageSafeObject(buildPatchSnapshot('retro-start')),
    });
  }, [buildPatchSnapshot, recorderState.availableSeconds, recorderState.recording, recorderState.rollingSeconds]);

  const applyRecipePatch = useCallback((patch: any) => {
    if (!patch || typeof patch !== 'object') return;
    const numberOr = (value: unknown, fallback: number) =>
      typeof value === 'number' && Number.isFinite(value) ? value : fallback;
    const boolOr = (value: unknown, fallback: boolean) =>
      typeof value === 'boolean' ? value : fallback;

    const model = patch.model ?? {};
    const pca = Array.isArray(patch.pca?.coefficients) ? patch.pca.coefficients : [];
    const nextParams: ParamsState = {
      ...paramsState,
      temperature: numberOr(model.temperature, paramsState.temperature),
      topk: numberOr(model.topk, paramsState.topk),
      cfgmusiccoca: numberOr(model.prompt_cfg, paramsState.cfgmusiccoca),
      cfgnotes: numberOr(model.note_cfg, paramsState.cfgnotes),
      cfgdrums: numberOr(model.drums_cfg, paramsState.cfgdrums),
      unmaskwidth: numberOr(model.unmask_width, paramsState.unmaskwidth),
      buffersize: numberOr(model.buffer_size, paramsState.buffersize),
      volume: numberOr(model.volume, paramsState.volume),
      drumless: boolOr(model.no_drums, paramsState.drumless),
      seedrotation: numberOr(model.seed_rotation, paramsState.seedrotation),
      pca_coeff_0: numberOr(pca[0], paramsState.pca_coeff_0),
      pca_coeff_1: numberOr(pca[1], paramsState.pca_coeff_1),
      pca_coeff_2: numberOr(pca[2], paramsState.pca_coeff_2),
      pca_coeff_3: numberOr(pca[3], paramsState.pca_coeff_3),
      pca_coeff_4: numberOr(pca[4], paramsState.pca_coeff_4),
      pca_coeff_5: numberOr(pca[5], paramsState.pca_coeff_5),
    };
    applyParamsState(nextParams);

    const rvqValues = patch.rvq?.values ?? {};
    const damage = patch.damage ?? {};
    const nextFx: FxState = {
      ...fxState,
      wet: numberOr(damage.wet, fxState.wet),
      drive: numberOr(damage.drive, fxState.drive),
      fold: numberOr(damage.fold, fxState.fold),
      crush: numberOr(damage.crush, fxState.crush),
      ring: numberOr(damage.ring, fxState.ring),
      comb: numberOr(damage.comb, fxState.comb),
      body: numberOr(damage.body, fxState.body),
      smear: numberOr(damage.smear, fxState.smear),
      stutter: numberOr(damage.stutter, fxState.stutter),
      pitch: numberOr(damage.pitch, fxState.pitch),
      harmonics: numberOr(damage.harmonics, fxState.harmonics),
      noise: numberOr(damage.noise, fxState.noise),
      rvqForce: numberOr(rvqValues.rvqForce, fxState.rvqForce),
      rvqBreathe: numberOr(rvqValues.rvqBreathe, fxState.rvqBreathe),
      rvqMemory: numberOr(rvqValues.rvqMemory, fxState.rvqMemory),
      rvqCoarse: numberOr(rvqValues.rvqCoarse, fxState.rvqCoarse),
      rvqFine: numberOr(rvqValues.rvqFine, fxState.rvqFine),
      rvqSweep: numberOr(rvqValues.rvqSweep, fxState.rvqSweep),
      rvqHold: numberOr(rvqValues.rvqHold, fxState.rvqHold),
      rvqInvert: numberOr(rvqValues.rvqInvert, fxState.rvqInvert),
      rvqJitter: numberOr(rvqValues.rvqJitter, fxState.rvqJitter),
      rvqStride: numberOr(rvqValues.rvqStride, fxState.rvqStride),
    };
    rvqPedalBaseRef.current = null;
    applyFxState(nextFx);
    setRvqPedals(cloneRvqPedals(patch.rvq?.pedals ?? createDefaultRvqPedals()));

    const performance = patch.performance ?? {};
    setPerformanceState({
      drift: numberOr(performance.drift, performanceState.drift),
      snapback: numberOr(performance.snapback, performanceState.snapback),
    });

    const textEncoder = patch.text_encoder ?? {};
    setTextLabState({
      warp: numberOr(textEncoder.warp, textLabState.warp),
      scramble: numberOr(textEncoder.scramble, textLabState.scramble),
      morph: numberOr(textEncoder.morph, textLabState.morph),
      oppose: numberOr(textEncoder.oppose, textLabState.oppose),
      scan: numberOr(textEncoder.scan, textLabState.scan),
      gravity: numberOr(textEncoder.gravity, textLabState.gravity),
    });
    setTextLabStatus(textEncoder.status === 'VEC' ? 'VEC' : 'RAW');

    const surface = patch.prompt_surface ?? {};
    const restoredPrompts: ConfabulatorPromptNode[] = Array.isArray(surface.prompts)
      ? surface.prompts
        .map((prompt: any, index: number) => {
          const id = Number.isFinite(Number(prompt.id)) ? Number(prompt.id) : index;
          const bankEmbedding = Array.isArray(prompt.bankEmbedding) && prompt.bankEmbedding.length === TEXT_EMBEDDING_DIM
            ? prompt.bankEmbedding.map((value: unknown) => Number(value))
            : undefined;
          const textEmbedding = Array.isArray(prompt.textEmbedding) && prompt.textEmbedding.length === TEXT_EMBEDDING_DIM
            ? prompt.textEmbedding.map((value: unknown) => Number(value))
            : undefined;
          const node: ConfabulatorPromptNode = {
            id,
            label: typeof prompt.label === 'string' ? prompt.label : `PATCH ${index + 1}`,
            x: numberOr(prompt.x, 120 + index * 44),
            y: numberOr(prompt.y, 120 + index * 44),
            colorIndex: Number.isFinite(Number(prompt.colorIndex)) ? Number(prompt.colorIndex) : index,
            isAudio: prompt.kind === 'audio',
            isBank: !!bankEmbedding || !!prompt.isBank,
            bankId: typeof prompt.bankId === 'string' ? prompt.bankId : undefined,
            bankEmbedding,
            textEmbedding,
          };
          return node;
        })
        .filter((prompt: ConfabulatorPromptNode) => prompt.label.trim().length > 0)
        .slice(0, MAX_ENGINE_PROMPTS)
      : [];
    if (restoredPrompts.length > 0) {
      setPrompts(restoredPrompts);
      nextIdRef.current = Math.max(3, ...restoredPrompts.map((prompt) => prompt.id + 1));
      nextColorRef.current = Math.max(3, ...restoredPrompts.map((prompt) => prompt.colorIndex + 1));
    }
    if (surface.listener && typeof surface.listener === 'object') {
      setListener({
        x: numberOr(surface.listener.x, listenerRef.current.x),
        y: numberOr(surface.listener.y, listenerRef.current.y),
      });
    }
    if (typeof surface.selectedBallId === 'number') {
      setSelectedBallId(surface.selectedBallId);
    }
    setSliderPos(numberOr(surface.sliderPos, sliderPos));
    setCollisionsEnabled(boolOr(surface.collisionsEnabled, collisionsEnabled));

    const selectedRecipeBankSet = patch.embeddings?.selectedBankSetId;
    const selectedRecipeBankId = patch.embeddings?.selectedBankId;
    if (typeof selectedRecipeBankSet === 'string' && bankSets.some((bank) => bank.id === selectedRecipeBankSet)) {
      setSelectedBankSetId(selectedRecipeBankSet);
    }
    if (typeof selectedRecipeBankId === 'string') {
      setSelectedBankId(selectedRecipeBankId);
    }

    setRecorderState(previous => ({ ...previous, status: 'recipe loaded', error: undefined }));
    window.setTimeout(() => {
      sendPrompts();
      kickGeneration();
    }, 180);
  }, [
    applyFxState,
    applyParamsState,
    bankSets,
    collisionsEnabled,
    fxState,
    kickGeneration,
    paramsState,
    performanceState,
    sendPrompts,
    sliderPos,
    textLabState,
  ]);

  const handleRecipeFile = useCallback((file?: File) => {
    if (!file) return;
    setRecorderState(previous => ({ ...previous, status: 'loading recipe', error: undefined }));
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const parsed = JSON.parse(String(reader.result));
        applyRecipePatch(parsed.patch ?? parsed);
      } catch (error) {
        setRecorderState(previous => ({
          ...previous,
          status: 'error',
          error: error instanceof Error ? error.message : 'Could not load recipe.',
        }));
      }
    };
    reader.onerror = () => {
      setRecorderState(previous => ({
        ...previous,
        status: 'error',
        error: 'Could not read recipe file.',
      }));
    };
    reader.readAsText(file);
  }, [applyRecipePatch]);

  const buildAgentSnapshot = useCallback(() => {
    const currentPrompts = promptsRef.current;
    const weights = calculateWeights(listenerRef.current, currentPrompts);
    return {
      schema_version: 1,
      timestamp: new Date().toISOString(),
      modelName,
      isPlaying,
      params: { ...paramsState },
      damage: {
        wet: fxState.wet,
        drive: fxState.drive,
        fold: fxState.fold,
        crush: fxState.crush,
        ring: fxState.ring,
        comb: fxState.comb,
        body: fxState.body,
        smear: fxState.smear,
        stutter: fxState.stutter,
        pitch: fxState.pitch,
        harmonics: fxState.harmonics,
        noise: fxState.noise,
      },
      rvq: {
        values: readRvqValues(),
        pedals: cloneRvqPedals(rvqPedals),
      },
      performance: { ...performanceState },
      text_encoder: {
        status: textLabStatusLabel,
        ...textLabState,
      },
      recorder: { ...recorderState },
      prompt_surface: {
        listener: { ...listenerRef.current },
        selectedBallId,
        sliderPos,
        physicsSpeed,
        collisionsEnabled,
        prompts: currentPrompts.map((prompt, index) => ({
          id: prompt.id,
          label: prompt.label,
          x: prompt.x,
          y: prompt.y,
          weight: weights[index] ?? 0,
          colorIndex: prompt.colorIndex,
          kind: prompt.isAudio ? 'audio' : (prompt.bankEmbedding ? 'embedding' : (prompt.textEmbedding ? 'text-vector' : 'text')),
          isBank: !!prompt.isBank,
          bankId: prompt.bankId,
        })),
      },
      embeddings: {
        selectedBankSetId,
        selectedBankSetLabel: activeBank?.label,
        selectedBankId,
        selectedBankLabel: selectedBankItem ? bankLabel(selectedBankItem) : undefined,
        activeBankItemCount: activeBankItems.length,
      },
      agent: { ...agentStatus },
    };
  }, [
    activeBank,
    activeBankItems.length,
    agentStatus,
    bankLabel,
    collisionsEnabled,
    fxState,
    isPlaying,
    modelName,
    paramsState,
    performanceState,
    physicsSpeed,
    recorderState,
    rvqPedals,
    selectedBallId,
    selectedBankId,
    selectedBankItem,
    selectedBankSetId,
    sliderPos,
    textLabState,
    textLabStatusLabel,
  ]);

  useEffect(() => {
    const publish = () => {
      post({ type: 'agentState', value: toMessageSafeObject(buildAgentSnapshot()) });
    };
    publish();
    const timer = window.setInterval(publish, 250);
    return () => window.clearInterval(timer);
  }, [buildAgentSnapshot]);

  useEffect(() => {
    post({
      type: 'agentCatalog',
      value: toMessageSafeObject({
        schema_version: 1,
        version: Date.now(),
        protocol: 'confabulator-agent-jsonl',
        commands: {
          core: Object.entries(PARAM_KEY_TO_ADDRESS).map(([key, address]) => ({ key, address })),
          damage: ['wet', 'drive', 'fold', 'crush', 'ring', 'comb', 'body', 'smear', 'stutter', 'pitch', 'harmonics', 'noise'],
          rvq: [...RVQ_KEYS],
          text_encoder: ['warp', 'scramble', 'morph', 'oppose', 'scan', 'gravity'],
          performance: ['drift', 'snapback'],
          macros: ['metal', 'melt', 'shred', 'ghost'],
          recorder: ['recordStart', 'recordStop', 'captureLast', 'setRecordingWindow'],
        },
        embeddings: {
          banks: bankSets.map((bank) => ({
            id: bank.id,
            label: bank.label,
            count: bank.items.length,
            items: bank.items.map((item) => ({
              id: item.id,
              label: bankLabel(item),
              bank: item.bank ?? bank.id,
              features: item.features,
              root: item.root,
              brightness: item.brightness,
              density: item.density,
              rhythm: item.rhythm,
              styleTokens: item.styleTokens,
            })),
          })),
        },
      }),
    });
  }, [bankLabel, bankSets]);

  const executeAgentCommand = useCallback((command: any) => {
    if (!command || typeof command !== 'object') return;
    const commandType = typeof command.type === 'string' ? command.type : '';
    appendAgentEvent('in', command);
    const clamp = (value: unknown, min = 0, max = 1) => {
      const number = Number(value);
      if (!Number.isFinite(number)) return undefined;
      return Math.max(min, Math.min(max, number));
    };
    const promptIdFrom = (value: unknown) => {
      const number = Number(value);
      return Number.isFinite(number) ? number : undefined;
    };
    const selectedOrFirstPromptId = () => selectedBallId ?? promptsRef.current[0]?.id;
    const findEmbedding = () => {
      const wantedId = String(command.bankId ?? command.embeddingId ?? command.itemId ?? '');
      const wantedLabel = typeof command.label === 'string' ? command.label.trim().toLowerCase() : '';
      return allBankItems.find((item) => item.id === wantedId)
        ?? (wantedLabel ? allBankItems.find((item) => bankLabel(item).toLowerCase() === wantedLabel || item.label.toLowerCase() === wantedLabel) : undefined)
        ?? (typeof command.bankSetId === 'string'
          ? bankSets.find((bank) => bank.id === command.bankSetId)?.items[Math.max(0, Number(command.index ?? 0))] : undefined);
    };

    if (commandType === 'setParam') {
      const address = typeof command.address === 'number'
        ? command.address
        : PARAM_KEY_TO_ADDRESS[command.key as keyof ParamsState];
      const value = Number(command.value);
      if (typeof address === 'number' && Number.isFinite(value)) sendParamChange(address, value);
    } else if (commandType === 'setCore') {
      const values = command.values && typeof command.values === 'object' ? command.values : command;
      (Object.entries(PARAM_KEY_TO_ADDRESS) as [keyof ParamsState, number][]).forEach(([key, address]) => {
        if (values[key] !== undefined) {
          const value = key === 'drumless' ? (values[key] ? 1 : 0) : Number(values[key]);
          if (Number.isFinite(value)) sendParamChange(address, value);
        }
      });
    } else if (commandType === 'setFx' || commandType === 'setDamage') {
      const values = command.values && typeof command.values === 'object' ? command.values : { [command.key]: command.value };
      (Object.keys(DEFAULT_FX_STATE) as (keyof FxState)[]).forEach((key) => {
        if (!key.startsWith('rvq') && values[key] !== undefined) {
          const value = clamp(values[key]);
          if (value !== undefined) sendFxChange(key, value);
        }
      });
    } else if (commandType === 'setRvq') {
      const values = command.values && typeof command.values === 'object' ? command.values : { [command.key]: command.value };
      RVQ_KEYS.forEach((key) => {
        if (values[key] !== undefined) {
          const value = clamp(values[key]);
          if (value !== undefined) handleRvqManualChange(key, value);
        }
      });
    } else if (commandType === 'setPerformance') {
      (['drift', 'snapback'] as (keyof PerformanceState)[]).forEach((key) => {
        if (command[key] !== undefined || command.values?.[key] !== undefined) {
          const value = clamp(command.values?.[key] ?? command[key]);
          if (value !== undefined) setPerformanceKey(key, value);
        }
      });
    } else if (commandType === 'setTextLab') {
      (['warp', 'scramble', 'morph', 'oppose', 'scan', 'gravity'] as (keyof TextLabState)[]).forEach((key) => {
        if (command[key] !== undefined || command.values?.[key] !== undefined) {
          const value = clamp(command.values?.[key] ?? command[key]);
          if (value !== undefined) setTextLabKey(key, value);
        }
      });
    } else if (commandType === 'moveListener') {
      const x = Number(command.x);
      const y = Number(command.y);
      if (Number.isFinite(x) && Number.isFinite(y)) setListener({ x, y });
    } else if (commandType === 'movePrompt') {
      const id = promptIdFrom(command.promptId ?? command.id) ?? selectedOrFirstPromptId();
      const x = Number(command.x);
      const y = Number(command.y);
      if (id !== undefined && Number.isFinite(x) && Number.isFinite(y)) {
        setPrompts(prev => prev.map(prompt => prompt.id === id ? { ...prompt, x, y } : prompt));
      }
    } else if (commandType === 'setPromptText') {
      const id = promptIdFrom(command.promptId ?? command.id) ?? selectedOrFirstPromptId();
      if (id !== undefined && typeof command.text === 'string') {
        handleTextChange(id, command.text);
      }
    } else if (commandType === 'selectPrompt') {
      const id = promptIdFrom(command.promptId ?? command.id);
      if (id !== undefined) setSelectedBallId(id);
    } else if (commandType === 'selectEmbedding') {
      const item = findEmbedding();
      if (item) {
        if (command.add) {
          addBankPrompt(item);
        } else {
          const id = promptIdFrom(command.promptId ?? command.id) ?? selectedOrFirstPromptId();
          if (id !== undefined) {
            const existing = promptsRef.current.find((prompt) => prompt.id === id);
            if (existing?.isAudio) post({ type: 'clearAudioPrompt' });
            setPrompts(prev => prev.map(prompt => prompt.id === id ? { ...prompt, ...bankPromptPatch(item) } : prompt));
            setSelectedBallId(id);
          } else {
            addBankPrompt(item);
          }
        }
        setBankControlsToItem(item);
      }
    } else if (commandType === 'setEmbeddings' && Array.isArray(command.items)) {
      const items = command.items
        .map((entry: any) => allBankItems.find((item) => item.id === entry || item.id === entry?.id || item.id === entry?.bankId))
        .filter(Boolean) as ConfabulatorBankItem[];
      if (items.length > 0) {
        setPrompts(prev => prev.map((prompt, index) => items[index] ? { ...prompt, ...bankPromptPatch(items[index]) } : prompt));
        setBankControlsToItem(items[0]);
        setSelectedBallId(promptsRef.current[0]?.id ?? null);
      }
    } else if (commandType === 'randomCore') {
      randomizeConfabulator();
    } else if (commandType === 'randomDamage') {
      randomizeDamage();
    } else if (commandType === 'jolt') {
      joltConfabulator();
    } else if (commandType === 'clean') {
      cleanConfabulator();
    } else if (commandType === 'macro') {
      const name = command.name;
      if (name === 'metal' || name === 'melt' || name === 'shred' || name === 'ghost') {
        applyMacro(name);
      }
    } else if (commandType === 'recordStart') {
      if (!recorderState.recording) toggleRetroRecorder();
    } else if (commandType === 'recordStop') {
      if (recorderState.recording) toggleRetroRecorder();
    } else if (commandType === 'captureLast') {
      const seconds = clamp(command.seconds ?? recorderState.rollingSeconds, 1, recorderState.rollingSeconds) ?? recorderState.rollingSeconds;
      captureRecorderWindow(seconds, typeof command.mode === 'string' ? command.mode : 'agent');
    } else if (commandType === 'setRecordingWindow') {
      const seconds = clamp(command.seconds, 10, 120);
      if (seconds !== undefined) requestRecorderWindow(seconds);
    } else if (commandType === 'play') {
      const target = typeof command.value === 'boolean' ? command.value : true;
      if (target !== isPlaying) togglePlay();
    } else if (commandType === 'togglePlay') {
      togglePlay();
    } else if (commandType === 'kick') {
      kickGeneration();
    } else if (commandType === 'loadRecipe') {
      applyRecipePatch(command.patch ?? command.recipe);
    }

    appendAgentEvent('out', { handled: commandType || 'unknown' });
  }, [
    addBankPrompt,
    allBankItems,
    appendAgentEvent,
    applyMacro,
    applyRecipePatch,
    bankLabel,
    bankPromptPatch,
    bankSets,
    captureRecorderWindow,
    cleanConfabulator,
    handleRvqManualChange,
    handleTextChange,
    isPlaying,
    joltConfabulator,
    kickGeneration,
    randomizeConfabulator,
    randomizeDamage,
    recorderState.recording,
    recorderState.rollingSeconds,
    requestRecorderWindow,
    selectedBallId,
    setBankControlsToItem,
    setPerformanceKey,
    setTextLabKey,
    togglePlay,
    toggleRetroRecorder,
  ]);

  useEffect(() => {
    if (agentCommandQueueRef.current.length === 0) return;
    const commands = agentCommandQueueRef.current.splice(0);
    commands.forEach((command) => executeAgentCommand(command));
  }, [agentCommandPulse, executeAgentCommand]);

  // ─── Render ────────────────────────────────────────────────────────
  const pcaValues = [
    paramsState.pca_coeff_0,
    paramsState.pca_coeff_1,
    paramsState.pca_coeff_2,
    paramsState.pca_coeff_3,
    paramsState.pca_coeff_4,
    paramsState.pca_coeff_5,
  ];
  const recorderAvailable = Math.max(0, recorderState.availableSeconds);
  const recorderStatus = recorderState.error
    ? `ERR: ${recorderState.error}`
    : recorderState.filePath
      ? recorderState.filePath
      : recorderState.status ?? 'idle';

  return (
    <div className="confabulator-app" style={{ width: '100vw', display: 'flex', flexDirection: 'column', background: 'var(--color-bg)' }}>
      {/* Transport — top left */}
      <div style={{
        position: 'fixed',
        top: 'var(--app-padding)',
        left: 'var(--app-padding)',
        zIndex: 10,
        color: '#FFF',
      }}>
        <TransportControls
          isPlaying={isPlaying}
          onTogglePlay={togglePlay}
          volume={paramsState.volume}
          onVolumeChange={(v) => sendParamChange(5, v)}
          onReset={resetModel}
          volumeSliderPosition="bottom"
          model={modelName}
        />
      </div>

      {/* Model selector + Settings — top right */}
      <div style={{
        position: 'fixed',
        top: 'var(--app-padding)',
        right: 'var(--app-padding)',
        zIndex: 10,
        display: 'flex',
        alignItems: 'center',
        gap: '12px',
        color: '#FFF',
      }}>
        <ModelSelector
          modelName={modelName}
          localModels={localModels}
          remoteModels={remoteModels}
          downloadProgress={downloadProgress}

          onSelectModel={(name: string) => post({ type: 'selectModel', name })}
          onDownloadModel={(name: string) => post({ type: 'downloadModel', name })}
          onDeleteModel={(name: string) => post({ type: 'deleteModel', name })}
          onSelectFolder={() => post({ type: 'selectDownloadFolder' })}
        />
        <IconButton
          onClick={() => setIsSettingsOpen(true)}
          variant="ghost"
          sx={{
            width: 40,
            height: 40,
          }}
          title="Settings (Cmd+,)"
        >
          <TuneIcon sx={{ fontSize: 20 }} />
        </IconButton>
      </div>

      <div className="confabulator-title">
        <b>CONFABULATOR</b>
        <span>MAGENTA RT</span>
      </div>

      <div
        className={agentStatus.enabled ? 'confabulator-agent-badge is-live' : 'confabulator-agent-badge'}
        title="Local agent performance socket"
      >
        <b>AGENT</b>
        <span>
          {agentStatus.enabled
            ? `${agentStatus.host ?? '127.0.0.1'}:${agentStatus.port ?? 47873}`
            : 'OFF'}
        </span>
        {agentStatus.lastCommand && <em>{agentStatus.lastCommand}</em>}
      </div>

      {/* Audio Meter — left edge, vertical, centered */}
      {/* <div style={{
        position: 'fixed',
        right: '34px',
        top: '50%',
        transform: 'translateY(-50%) rotate(-90deg) translateX(50%)',
        transformOrigin: 'top right',
        zIndex: 10,
        pointerEvents: 'none',
      }}>
        <AudioMeter leftLevel={audioLevel} rightLevel={audioLevel} width="120px" height="14px" />
      </div> */}

      {/* Top spacer — keeps prompt surface below fixed header elements */}
      <div style={{ height: 'calc(var(--app-padding) + 56px + var(--app-padding))', flexShrink: 0 }} />

      {/* PromptSurface */}
      <div ref={promptSurfaceRef} className="confabulator-prompt-surface">
        <PromptSurface
          prompts={prompts}
          listener={listener}
          selectedBallId={selectedBallId}
          onPromptMove={handlePromptMove}
          onListenerMove={handleListenerMove}
          onBallSelect={handleBallSelect}
          onPromptAdd={handlePromptAdd}
          onPromptTextChange={handleTextChange}
          onPromptDelete={handlePromptDelete}
          physicsSpeed={physicsSpeed}
          onFirstThrow={handleFirstThrow}
          isPlaying={isPlaying}
          audioLevel={audioLevel}
          debug={debug}
          collisions={collisionsEnabled}
        />
      </div>

      <section className="confabulator-rack" aria-label="CONFABULATOR manipulation controls">
        <div className="confabulator-rack-head">
          <b>MANIPULATE</b>
          <div className="confabulator-recorder-strip" aria-label="Rolling recorder">
            <span className={recorderState.recording ? 'confabulator-recorder-led is-recording' : 'confabulator-recorder-led'}>
              {recorderState.recording
                ? `REC ${recorderState.recordingSeconds.toFixed(1)}s`
                : `ROLL ${recorderAvailable.toFixed(1)}s`}
            </span>
            <select
              aria-label="Rolling buffer length"
              value={recorderState.rollingSeconds}
              onChange={(event) => requestRecorderWindow(Number(event.currentTarget.value))}
            >
              {[10, 30, 60, 120].map((seconds) => (
                <option key={seconds} value={seconds}>{`${seconds}s`}</option>
              ))}
            </select>
            <button
              type="button"
              className={recorderState.recording ? 'is-hot' : undefined}
              onClick={toggleRetroRecorder}
            >
              {recorderState.recording ? 'STOP' : 'REC'}
            </button>
            {[5, 10, 30, 60].map((seconds) => (
              <button
                key={seconds}
                type="button"
                disabled={recorderAvailable < 0.5}
                onClick={() => captureRecorderWindow(seconds, `last-${seconds}s`)}
              >
                {`LAST ${seconds}s`}
              </button>
            ))}
            <button
              type="button"
              disabled={recorderAvailable < 0.5}
              title={`Save the current rolling buffer, up to ${recorderState.rollingSeconds} seconds, with a recipe file.`}
              onClick={() => captureRecorderWindow(recorderState.rollingSeconds, 'save')}
            >
              SAVE BUFFER
            </button>
            <button
              type="button"
              disabled={recorderAvailable < 0.5}
              title="Save a quick 30-second clip with a recipe file."
              onClick={() => captureRecorderWindow(Math.min(30, recorderState.rollingSeconds), 'sketch')}
            >
              QUICK 30S
            </button>
            <button type="button" onClick={() => recipeInputRef.current?.click()}>
              LOAD RECIPE
            </button>
            <input
              ref={recipeInputRef}
              className="confabulator-recipe-input"
              type="file"
              accept=".json,.confab.json,application/json"
              onChange={(event) => {
                handleRecipeFile(event.currentTarget.files?.[0]);
                event.currentTarget.value = '';
              }}
            />
            <span className="confabulator-recorder-path" title={recorderStatus}>{recorderStatus}</span>
          </div>
          <div className="confabulator-rack-main-actions">
            <button type="button" onClick={cleanConfabulator}>CLEAN</button>
            <button type="button" onClick={randomizeConfabulator}>RANDOM CORE</button>
          </div>
        </div>

        <div className="confabulator-rack-grid">
          <div className="confabulator-module">
            <div className="confabulator-module-head">
              <b>MODEL</b>
              <label className="confabulator-toggle compact">
                <span>NO DRUMS</span>
                <input
                  type="checkbox"
                  checked={paramsState.drumless}
                  onChange={(event) => sendParamChange(39, event.currentTarget.checked ? 1 : 0)}
                />
              </label>
            </div>
            <ConfabulatorSlider label="CHAOS" value={paramsState.temperature} min={0} max={3} step={0.01} onChange={(v) => sendParamChange(0, v)} />
            <ConfabulatorSlider label="TOKEN K" value={paramsState.topk} min={1} max={1024} step={1} digits={0} onChange={(v) => sendParamChange(1, Math.round(v))} />
            <ConfabulatorSlider label="PROMPT CFG" value={paramsState.cfgmusiccoca} min={0} max={5} step={0.1} onChange={(v) => sendParamChange(3, v)} />
            <ConfabulatorSlider label="UNMASK" value={paramsState.unmaskwidth} min={0} max={127} step={1} digits={0} onChange={(v) => sendParamChange(7, Math.round(v))} />
            <ConfabulatorSlider label="SEED ROT" value={paramsState.seedrotation} min={0} max={1000} step={1} digits={0} onChange={(v) => sendParamChange(47, Math.round(v))} />
          </div>

          <div className="confabulator-module">
            <div className="confabulator-module-head">
              <b>DAMAGE</b>
              <div>
                <button type="button" onClick={randomizeDamage}>RANDOM</button>
                <button type="button" onClick={resetFx}>ZERO</button>
              </div>
            </div>
            <ConfabulatorSlider label="WET" value={fxState.wet} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('wet', v)} />
            <ConfabulatorSlider label="DRIVE" value={fxState.drive} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('drive', v)} />
            <ConfabulatorSlider label="FOLD" value={fxState.fold} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('fold', v)} />
            <ConfabulatorSlider label="CRUSH" value={fxState.crush} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('crush', v)} />
            <ConfabulatorSlider label="RING" value={fxState.ring} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('ring', v)} />
            <ConfabulatorSlider label="COMB" value={fxState.comb} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('comb', v)} />
            <ConfabulatorSlider label="BODY" value={fxState.body} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('body', v)} />
            <ConfabulatorSlider label="SMEAR" value={fxState.smear} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('smear', v)} />
            <ConfabulatorSlider label="STUTTER" value={fxState.stutter} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('stutter', v)} />
            <ConfabulatorSlider label="PITCH" value={fxState.pitch} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('pitch', v)} />
            <ConfabulatorSlider label="HARM" value={fxState.harmonics} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('harmonics', v)} />
            <ConfabulatorSlider label="NOISE" value={fxState.noise} min={0} max={1} step={0.01} onChange={(v) => sendFxChange('noise', v)} />
          </div>

          <div className="confabulator-module confabulator-rvq-module">
            <div className="confabulator-module-head">
              <b>SPECTROSTREAM RVQ</b>
              <button type="button" onClick={clearRvqControls}>CLEAR</button>
            </div>
            <ConfabulatorSlider label="FORCE" value={fxState.rvqForce} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqForce', v)} />
            <ConfabulatorSlider label="BREATHE" value={fxState.rvqBreathe} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqBreathe', v)} />
            <ConfabulatorSlider label="MEMORY" value={fxState.rvqMemory} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqMemory', v)} />
            <ConfabulatorSlider label="COARSE" value={fxState.rvqCoarse} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqCoarse', v)} />
            <ConfabulatorSlider label="FINE" value={fxState.rvqFine} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqFine', v)} />
            <ConfabulatorSlider label="SWEEP" value={fxState.rvqSweep} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqSweep', v)} />
            <ConfabulatorSlider label="HOLD" value={fxState.rvqHold} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqHold', v)} />
            <ConfabulatorSlider label="INVERT" value={fxState.rvqInvert} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqInvert', v)} />
            <ConfabulatorSlider label="JITTER" value={fxState.rvqJitter} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqJitter', v)} />
            <ConfabulatorSlider label="STRIDE" value={fxState.rvqStride} min={0} max={1} step={0.01} onChange={(v) => handleRvqManualChange('rvqStride', v)} />
            <div className="confabulator-rvq-pedals">
              <div className="confabulator-pedals-head">
                <b>RVQ PEDALS</b>
                <button type="button" onClick={() => setAllRvqPedalsInactive(true)}>OFF</button>
              </div>
              {RVQ_PEDAL_DEFS.map((pedal) => (
                <div className="confabulator-pedal-row" key={pedal.id}>
                  <button
                    type="button"
                    className={rvqPedals[pedal.id].active ? 'is-hot' : undefined}
                    title={pedal.result}
                    onPointerDown={() => handleRvqPedalPointerDown(pedal.id)}
                    onPointerUp={() => handleRvqPedalPointerUp(pedal.id)}
                    onPointerLeave={() => handleRvqPedalPointerUp(pedal.id)}
                    onClick={() => handleRvqPedalClick(pedal.id)}
                  >
                    {pedal.label}
                  </button>
                  <input
                    aria-label={`${pedal.label} mix`}
                    type="range"
                    min="0"
                    max="1"
                    step="0.01"
                    value={rvqPedals[pedal.id].mix}
                    onChange={(event) => updateRvqPedal(pedal.id, { mix: Number(event.currentTarget.value) })}
                  />
                  <select
                    aria-label={`${pedal.label} mode`}
                    value={rvqPedals[pedal.id].mode}
                    onChange={(event) => updateRvqPedal(pedal.id, { mode: event.currentTarget.value as RvqPedalMode })}
                  >
                    <option value="toggle">TOG</option>
                    <option value="hold">HOLD</option>
                    <option value="latch">LATCH</option>
                  </select>
                </div>
              ))}
            </div>
          </div>

          <div className="confabulator-module">
            <div className="confabulator-module-head">
              <b>EMBEDDINGS</b>
              <span>{activeBankItems.length}</span>
            </div>
            <div className="confabulator-source-panel">
              <div className="confabulator-source-head">
                <b>SOURCE</b>
                <span>{sourceStatus}</span>
              </div>
              <div className="confabulator-source-name" title={sourceName || 'NO SOURCE'}>
                {sourceName || 'NO SOURCE'}
              </div>
              <div className="confabulator-bank-actions confabulator-source-actions">
                <button type="button" onClick={requestSourceEmbedding}>CREATE EMBED</button>
              </div>
            </div>
            <select
              className="confabulator-bank-select"
              value={selectedBankSetId}
              onChange={(event) => handleBankSetChange(event.currentTarget.value)}
            >
              {bankSets.map((bank) => (
                <option key={bank.id} value={bank.id}>{`${bank.label} (${bank.items.length})`}</option>
              ))}
            </select>
            <select
              className="confabulator-bank-select"
              value={selectedBankId}
              onChange={(event) => handleBankItemChange(event.currentTarget.value)}
            >
              {activeBankItems.map((item, index) => (
                <option key={item.id} value={item.id}>{`${index + 1}. ${bankLabel(item)}`}</option>
              ))}
            </select>
            <div className="confabulator-bank-actions">
              <button type="button" onClick={() => addBankPrompt()}>ADD EMBED</button>
              <button
                type="button"
                disabled={!canApplyBankToSelected}
                onClick={() => applyBankToSelected()}
              >
                SET SELECTED
              </button>
              <button type="button" onClick={rerollSelectedOrAddBankPrompt}>REROLL EMBED</button>
            </div>
            <div className="confabulator-pca-head">
              <b>PCA STYLE</b>
              <button type="button" onClick={() => addPcaPrompt()}>ADD PCA</button>
            </div>
            <div className="confabulator-pca-grid">
              {PCA_PARAM_ADDRESSES.map((address, index) => (
                <ConfabulatorSlider
                  key={address}
                  label={`AXIS ${index + 1}`}
                  value={pcaValues[index]}
                  min={-3}
                  max={3}
                  step={0.01}
                  onChange={(v) => sendParamChange(address, v)}
                />
              ))}
            </div>
          </div>

          <div className="confabulator-module confabulator-text-lab">
            <div className="confabulator-module-head">
              <b>TEXT ENCODER</b>
              <span>{textLabStatusLabel}</span>
            </div>
            <div className="confabulator-bank-actions confabulator-text-actions">
              <button
                type="button"
                disabled={!canCaptureSelectedText}
                onClick={requestSelectedTextEmbedding}
                title="Capture the selected text prompt as a MusicCoCa vector so these dials can bend it."
              >
                CAPTURE
              </button>
              <button
                type="button"
                disabled={!canReleaseSelectedText}
                onClick={releaseSelectedTextEmbedding}
                title="Release the selected captured vector back to ordinary text-prompt encoding."
              >
                RAW
              </button>
              <button type="button" onClick={resetTextLab}>ZERO</button>
            </div>
            <ConfabulatorSlider label="CARVE" value={textLabState.warp} min={0} max={1} step={0.01} onChange={(v) => setTextLabKey('warp', v)} />
            <ConfabulatorSlider label="SCRAMBLE" value={textLabState.scramble} min={0} max={1} step={0.01} onChange={(v) => setTextLabKey('scramble', v)} />
            <ConfabulatorSlider label="MORPH" value={textLabState.morph} min={0} max={1} step={0.01} onChange={(v) => setTextLabKey('morph', v)} />
            <ConfabulatorSlider label="OPPOSE" value={textLabState.oppose} min={0} max={1} step={0.01} onChange={(v) => setTextLabKey('oppose', v)} />
            <ConfabulatorSlider label="SCAN" value={textLabState.scan} min={0} max={1} step={0.01} onChange={(v) => setTextLabKey('scan', v)} />
            <ConfabulatorSlider label="GRAVITY" value={textLabState.gravity} min={0} max={1} step={0.01} onChange={(v) => setTextLabKey('gravity', v)} />
          </div>

          <div className="confabulator-module">
            <div className="confabulator-module-head">
              <b>PERFORM</b>
              <button type="button" onClick={joltConfabulator}>JUMP</button>
            </div>
            <ConfabulatorSlider label="DRIFT" value={performanceState.drift} min={0} max={1} step={0.01} onChange={(v) => setPerformanceKey('drift', v)} />
            <ConfabulatorSlider label="SNAP" value={performanceState.snapback} min={0} max={1} step={0.01} onChange={(v) => setPerformanceKey('snapback', v)} />
            <div className="confabulator-macro-grid">
              <button type="button" onClick={() => applyMacro('metal')}>METAL</button>
              <button type="button" onClick={() => applyMacro('melt')}>MELT</button>
              <button type="button" onClick={() => applyMacro('shred')}>SHRED</button>
              <button type="button" onClick={() => applyMacro('ghost')}>GHOST</button>
            </div>
            <div className="confabulator-settings-head">
              <b>SETTINGS BANK</b>
              <span>{settingsBanks.length}</span>
            </div>
            <select
              className="confabulator-bank-select"
              value={selectedSettingsBankId}
              onChange={(event) => setSelectedSettingsBankId(event.currentTarget.value)}
            >
              <option value="">NO BANK</option>
              {settingsBanks.map((bank) => (
                <option key={bank.id} value={bank.id}>{bank.name}</option>
              ))}
            </select>
            <div className="confabulator-bank-actions">
              <button type="button" onClick={saveSettingsBank}>SAVE</button>
              <button type="button" disabled={!canLoadSettingsBank} onClick={() => loadSettingsBank()}>LOAD</button>
              <button type="button" disabled={!canLoadSettingsBank} onClick={deleteSettingsBank}>DELETE</button>
            </div>
          </div>
        </div>
      </section>

      {/* TimingIndicator — fixed bottom-left */}
      <div style={{
        position: 'fixed',
        bottom: 'calc(var(--app-padding) + 3px)',
        left: 'var(--app-padding)',
        zIndex: 10,
        color: 'var(--color-muted)',
      }}>
        <TimingIndicator frameMs={metrics.frameMs} droppedFrames={metrics.droppedFrames} buffersize={paramsState.buffersize} onBufferChange={(v) => sendParamChange(8, v)} isPlaying={isPlaying} bufferLabel="buffer" />
      </div>

      {/* ── Bottom bar ── */}
      <div style={{ display: 'flex', alignItems: 'center', padding: 'var(--app-padding)', flexShrink: 0, gap: '12px', position: 'relative', justifyContent: 'flex-end' }}>

        {/* Add Prompt */}
        <Tooltip title="Add prompt">
          <IconButton
            onClick={() => {
              const el = promptSurfaceRef.current;
              if (!el) return;
              const { width, height } = el.getBoundingClientRect();
              const pad = 60;
              const x = pad + Math.random() * (width - pad * 2);
              const y = pad + Math.random() * (height - pad * 2);
              handlePromptAdd(x, y);
            }}
            sx={{
              width: 40,
              height: 40,
            }}
          >
            <span className="material-icons" style={{ fontSize: '20px' }}>add</span>
          </IconButton>
        </Tooltip>

        {/* Speed slider — absolute, aligned to the right of the bar (left of Add Prompt) */}
        <div
          className={`speed-slider-dock${hasThrown ? ' visible' : ''}`}
          style={{
            position: 'absolute',
            bottom: 'calc(var(--app-padding) + 1px)',
            right: '88px',
            transform: hasThrown ? 'translateY(0)' : 'translateY(200%)',
            maxWidth: '260px',
            width: '100%',
            zIndex: 10,
            pointerEvents: hasThrown ? 'auto' : 'none',
            display: 'flex',
            alignItems: 'center',
          }}
        >
          <Tooltip title={collisionsEnabled ? "Collisions enabled" : "Collisions disabled"}>
            <IconButton
              onClick={() => setCollisionsEnabled(prev => !prev)}
              sx={{
                width: 32,
                height: 32,
                color: collisionsEnabled ? '#71fade' : '#FFF',
                mr: '11px',
                flexShrink: 0,
              }}
            >
              {collisionsEnabled ? (
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" style={{overflow: 'visible'}}>
                  <circle cx="4.5" cy="12" r="7" />
                  <circle cx="19.5" cy="12" r="7" />
                </svg>
              ) : (
                <span className="material-symbols-outlined" style={{ fontSize: '20px' }}>join</span>
              )}
            </IconButton>
          </Tooltip>
          <Turtle style={{ width: '20px', height: '20px', flexShrink: 0 }} color="white" strokeWidth={1.5} />
          <input
            type="range"
            min="0"
            max="1"
            step="0.005"
            value={sliderPos}
            onChange={(e) => setSliderPos(parseFloat(e.target.value))}
            onMouseDown={() => document.body.classList.add('is-dragging')}
            onMouseUp={() => document.body.classList.remove('is-dragging')}
            className={physicsSpeed === 0 ? 'speed-zero' : undefined}
            style={{ flex: 1 }}
          />
          <Rabbit style={{ width: '20px', height: '20px', flexShrink: 0 }} color="white" strokeWidth={1.5} />
        </div>
      </div>



      {/* <div
        className={`dev-badge${debug ? ' debug-on' : ''}`}
        onClick={() => setDebug(d => !d)}
      >DEV</div> */}
      <SettingsPanel
        open={isSettingsOpen}
        onClose={() => setIsSettingsOpen(false)}
        temperature={paramsState.temperature}
        topk={paramsState.topk}
        cfgnotes={paramsState.cfgnotes}
        cfgmusiccoca={paramsState.cfgmusiccoca}
        cfgdrums={paramsState.cfgdrums}
        unmaskwidth={paramsState.unmaskwidth}
        onParamChange={sendParamChange}
        onResetDefaults={handleResetDefaults}
        showNoteCfg={false}
        showPromptCfg={false}
        showDrumsCfg={false}
        showUnmaskWidth={false}
        showOnsetMode={false}
        showDrumless={true}
        columns={1}
        drumless={paramsState.drumless}
      />

      {resourcesMissing && (
        <ResourceOnboardingModal
          progress={resourcesProgress}
          remoteModels={remoteModels}
          downloadPath={downloadPath}
          isFetchingModels={isFetchingModels}

          onSelectFolder={() => post({ type: 'selectDownloadFolder' })}
          onStartDownload={(modelName) => post({ type: 'initResources', modelName })}
        />
      )}
    </div>
  );
}

export default App;
