import { useState, useEffect } from 'react';
import { Send, Loader2, CheckCircle, XCircle, Plus, X, AlertCircle } from 'lucide-react';
import type { TopicInfo } from '../../types';
import { getTopics, produceMessage } from '../../lib/api';

interface Props {
  clusterId: string;
}

interface HeaderEntry {
  key: string;
  value: string;
}

export default function ProduceMessage({ clusterId }: Props) {
  const [topics, setTopics] = useState<TopicInfo[]>([]);
  const [selectedTopic, setSelectedTopic] = useState('');
  const [key, setKey] = useState('');
  const [value, setValue] = useState('');
  const [headers, setHeaders] = useState<HeaderEntry[]>([]);
  const [showHeaders, setShowHeaders] = useState(false);
  const [sending, setSending] = useState(false);
  const [result, setResult] = useState<{ success: boolean; message: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [history, setHistory] = useState<Array<{ topic: string; key: string; value: string; time: string; success: boolean }>>([]);

  useEffect(() => {
    getTopics(clusterId).then(data => {
      setTopics(data);
      if (data.length > 0 && !selectedTopic) {
        setSelectedTopic(data[0].name);
      }
    }).catch(() => setTopics([]));
  }, [clusterId]);

  const addHeader = () => setHeaders([...headers, { key: '', value: '' }]);
  const removeHeader = (idx: number) => setHeaders(headers.filter((_, i) => i !== idx));
  const updateHeader = (idx: number, field: 'key' | 'value', val: string) => {
    const updated = [...headers];
    updated[idx][field] = val;
    setHeaders(updated);
  };

  const handleSend = async () => {
    if (!selectedTopic || !value.trim()) return;
    setSending(true);
    setResult(null);
    setError(null);
    try {
      const headerMap: Record<string, string> = {};
      headers.forEach(h => { if (h.key.trim()) headerMap[h.key.trim()] = h.value; });

      const res = await produceMessage(clusterId, {
        topic: selectedTopic,
        key: key.trim() || undefined,
        value: value.trim(),
        headers: Object.keys(headerMap).length > 0 ? headerMap : undefined,
      });
      setResult(res);
      setHistory(prev => [{
        topic: selectedTopic,
        key: key.trim(),
        value: value.trim(),
        time: new Date().toLocaleTimeString(),
        success: res.success,
      }, ...prev].slice(0, 20));
      if (res.success) {
        setValue('');
        setKey('');
      }
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail;
      setError(msg || 'Failed to produce message. Check broker connectivity.');
      setResult({ success: false, message: 'Failed to produce' });
    } finally {
      setSending(false);
    }
  };

  return (
    <div>
      <h3 className="text-sm font-semibold text-gray-700 mb-4">Produce Message</h3>

      <div className="bg-white border rounded-xl p-5 space-y-4">
        {/* Error banner */}
        {error && (
          <div className="flex items-center gap-2 bg-red-50 border border-red-200 rounded-lg px-3 py-2 text-sm text-red-700">
            <AlertCircle size={14} /> {error}
          </div>
        )}

        <div>
          <label className="block text-xs font-medium text-gray-600 mb-1">Topic</label>
          {topics.length === 0 ? (
            <p className="text-sm text-gray-400">No topics available. Create a topic first.</p>
          ) : (
            <select
              value={selectedTopic}
              onChange={e => setSelectedTopic(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg text-sm"
            >
              {topics.map(t => (
                <option key={t.name} value={t.name}>{t.name}</option>
              ))}
            </select>
          )}
        </div>

        <div>
          <label className="block text-xs font-medium text-gray-600 mb-1">Key (optional)</label>
          <input
            type="text"
            value={key}
            onChange={e => setKey(e.target.value)}
            placeholder="message-key"
            className="w-full px-3 py-2 border rounded-lg text-sm font-mono"
          />
        </div>

        <div>
          <label className="block text-xs font-medium text-gray-600 mb-1">Value</label>
          <textarea
            value={value}
            onChange={e => setValue(e.target.value)}
            placeholder='{"event": "test", "timestamp": 1234567890}'
            rows={4}
            className="w-full px-3 py-2 border rounded-lg text-sm font-mono resize-y"
          />
        </div>

        {/* Headers toggle */}
        <div>
          <button
            onClick={() => setShowHeaders(!showHeaders)}
            className="text-xs text-blue-600 hover:text-blue-800"
          >
            {showHeaders ? 'Hide headers' : 'Add headers (optional)'}
          </button>
          {showHeaders && (
            <div className="mt-2 space-y-2">
              {headers.map((h, i) => (
                <div key={i} className="flex items-center gap-2">
                  <input
                    type="text"
                    value={h.key}
                    onChange={e => updateHeader(i, 'key', e.target.value)}
                    placeholder="Header key"
                    className="flex-1 px-2.5 py-1.5 border rounded-lg text-xs font-mono"
                  />
                  <input
                    type="text"
                    value={h.value}
                    onChange={e => updateHeader(i, 'value', e.target.value)}
                    placeholder="Header value"
                    className="flex-1 px-2.5 py-1.5 border rounded-lg text-xs font-mono"
                  />
                  <button onClick={() => removeHeader(i)} className="p-1 text-gray-400 hover:text-red-600">
                    <X size={14} />
                  </button>
                </div>
              ))}
              <button onClick={addHeader} className="flex items-center gap-1 text-xs text-gray-500 hover:text-gray-700">
                <Plus size={12} /> Add header
              </button>
            </div>
          )}
        </div>

        <div className="flex items-center gap-3">
          <button
            onClick={handleSend}
            disabled={sending || !selectedTopic || !value.trim()}
            className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 disabled:opacity-50"
          >
            {sending ? <Loader2 size={15} className="animate-spin" /> : <Send size={15} />}
            Produce
          </button>
          {result && (
            <span className={`flex items-center gap-1 text-sm ${result.success ? 'text-green-600' : 'text-red-600'}`}>
              {result.success ? <CheckCircle size={15} /> : <XCircle size={15} />}
              {result.message}
            </span>
          )}
        </div>
      </div>

      {/* Recent sends */}
      {history.length > 0 && (
        <div className="mt-6">
          <h4 className="text-xs font-semibold text-gray-500 mb-2 uppercase tracking-wider">Recent Messages</h4>
          <div className="space-y-1">
            {history.map((h, i) => (
              <div key={i} className="flex items-center gap-3 text-xs bg-white border rounded-lg px-3 py-2">
                <span className={h.success ? 'text-green-500' : 'text-red-500'}>
                  {h.success ? <CheckCircle size={12} /> : <XCircle size={12} />}
                </span>
                <span className="text-gray-400">{h.time}</span>
                <span className="font-mono text-gray-700">{h.topic}</span>
                {h.key && <span className="text-gray-400">key={h.key}</span>}
                <span className="text-gray-500 truncate max-w-xs">{h.value}</span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
