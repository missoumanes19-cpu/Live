// Optional custom server (Xtream Codes login or direct M3U link).
// When saved, its channels are added on top of the built-in playlists.

export interface CustomServer {
  type: 'xtream' | 'm3u';
  host?: string;
  username?: string;
  password?: string;
  m3uUrl?: string;
}

const KEY = 'custom_server';

export function getCustomServer(): CustomServer | null {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as CustomServer) : null;
  } catch {
    return null;
  }
}

export function saveCustomServer(s: CustomServer) {
  localStorage.setItem(KEY, JSON.stringify(s));
}

export function clearCustomServer() {
  localStorage.removeItem(KEY);
}

function normalizeHost(h: string): string {
  let host = h.trim().replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(host)) host = `http://${host}`;
  return host;
}

export function buildServerUrl(s: CustomServer): string {
  if (s.type === 'm3u') return (s.m3uUrl || '').trim();
  const host = normalizeHost(s.host || '');
  const u = encodeURIComponent((s.username || '').trim());
  const p = encodeURIComponent((s.password || '').trim());
  return `${host}/get.php?username=${u}&password=${p}&type=m3u_plus&output=m3u8`;
}

/** Playlist URLs coming from the user's own server (empty if none saved). */
export function customServerUrls(kind: 'tv' | 'movie'): string[] {
  const s = getCustomServer();
  if (!s || kind !== 'tv') return [];
  const url = buildServerUrl(s);
  return url ? [url] : [];
}

/** Put the user's server first, then the built-in playlists. */
export function withCustomServer(urls: string[], kind: 'tv' | 'movie'): string[] {
  return [...customServerUrls(kind), ...urls];
}
