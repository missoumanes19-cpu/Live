import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import Layout from '@/components/Layout';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { toast } from 'sonner';
import { fetchAndParsePlaylist } from '@/lib/m3u-parser';
import {
  CustomServer, getCustomServer, saveCustomServer, clearCustomServer, buildServerUrl,
} from '@/lib/server';

const Server = () => {
  const navigate = useNavigate();
  const saved = getCustomServer();
  const [type, setType] = useState<'xtream' | 'm3u'>(saved?.type || 'xtream');
  const [host, setHost] = useState(saved?.host || '');
  const [username, setUsername] = useState(saved?.username || '');
  const [password, setPassword] = useState(saved?.password || '');
  const [m3uUrl, setM3uUrl] = useState(saved?.m3uUrl || '');
  const [busy, setBusy] = useState(false);

  const current = (): CustomServer => ({ type, host, username, password, m3uUrl });

  const valid = type === 'xtream' ? !!(host.trim() && username.trim() && password.trim()) : !!m3uUrl.trim();

  const handleSave = async () => {
    if (!valid) return toast.error('Please fill in all fields.');
    setBusy(true);
    const channels = await fetchAndParsePlaylist(buildServerUrl(current()));
    setBusy(false);
    if (channels.length === 0) {
      return toast.error('Could not load channels. Check the server details and try again.');
    }
    saveCustomServer(current());
    toast.success(`Connected — ${channels.length} channels loaded.`);
    navigate('/live');
  };

  const handleRemove = () => {
    clearCustomServer();
    setHost(''); setUsername(''); setPassword(''); setM3uUrl('');
    toast.success('Server removed. Built-in channels are still available.');
  };

  return (
    <Layout>
      <div className="container mx-auto px-4 py-10 max-w-md">
        <h1 className="text-2xl font-bold mb-1">Server (optional)</h1>
        <p className="text-sm text-muted-foreground mb-6">
          Add your own server to get its channels on top of the built-in list. You can skip this.
        </p>

        <div className="grid grid-cols-2 gap-2 mb-4">
          <Button variant={type === 'xtream' ? 'default' : 'outline'} onClick={() => setType('xtream')}>Xtream Codes</Button>
          <Button variant={type === 'm3u' ? 'default' : 'outline'} onClick={() => setType('m3u')}>M3U link</Button>
        </div>

        <div className="space-y-3">
          {type === 'xtream' ? (
            <>
              <Input placeholder="Server URL (http://host:port)" value={host} onChange={(e) => setHost(e.target.value)} autoCapitalize="none" />
              <Input placeholder="Username" value={username} onChange={(e) => setUsername(e.target.value)} autoCapitalize="none" />
              <Input placeholder="Password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
            </>
          ) : (
            <Input placeholder="https://example.com/playlist.m3u" value={m3uUrl} onChange={(e) => setM3uUrl(e.target.value)} autoCapitalize="none" />
          )}
        </div>

        <div className="mt-6 space-y-2">
          <Button className="w-full" disabled={busy} onClick={handleSave}>{busy ? 'Connecting…' : 'Save & connect'}</Button>
          {saved && <Button className="w-full" variant="outline" onClick={handleRemove}>Remove my server</Button>}
          <Button className="w-full" variant="ghost" onClick={() => navigate('/live')}>Skip — use built-in channels</Button>
        </div>
      </div>
    </Layout>
  );
};

export default Server;
