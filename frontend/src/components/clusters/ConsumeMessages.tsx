import { useState, useEffect } from 'react';
import { Download, Loader2, AlertCircle, Clock, Hash, Key } from 'lucide-react';
import type { TopicInfo, ConsumedMessage } from '../../types';
import { getTopics, consumeMessages } from '../../lib/api';

interface Props {
  clusterId: string;
}

export default function ConsumeMessages({ clusterId }: Props) {
  const [topics, setTopics] = useState<TopicInfo[]>([]);
  const [selectedTopic, setSelectedTopic] = useState('');
  const [fromBeginning, setFromBeginning] = useState(false);
  const [maxMessages, setMaxMessages] = useState(10);
  const [groupId, setGroupId] = useState('');
  const [timeoutMs, setTimeoutMs] = useState(10000);
  const [consuming, setConsuming] = useState(false);
  const [messages, setMessages] = useState<ConsumedMessage[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [expandedMsg, setExpandedMsg] = useState<number | null>(null);

  useEffect(() => {
    getTopics(clusterId).then(data => {
      setTopics(data);
      if (data.length > 0 && !selectedTopic) {
        setSelectedTopic(data[0].name);
      }
    }).catch(() => setTopics([]));
  }, [clusterId]);

  const handleConsume = async () => {
    if (!selectedTopic) return;
    setConsuming(true);
    setError(null);
    setMessages([]);
    try {
      const res = await consumeMessages(clusterId, {
        topic: selectedTopic,
        from_beginning: fromBeginning,
        max_messages: maxMessages,
        group_id: groupId || undefined,
        timeout_ms: timeoutMs,
      });
      setMessages(res.messages);
      if (res.count === 0) {
        setError('No messages found. Topic may be empty or consumer timed out.');
      }
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail;
      setError(msg || 'Failed to consume messages. Check broker connectivity.');
    } finally {
      setConsuming(false);
    }
  };

  const formatTimestamp = (ts: number | string | null): string => {
    if (ts === null) return '-';
    if (typeof ts === 'number') {
      try {
        return new Date(ts).toLocaleString();
      } catch {
        return String(ts);
      }
    }
    return String(ts);
  };

  return (
    <div>
      <h3 className="text-sm font-semibold text-gray-700 mb-4">Consume Messages</h3>

      {/* Controls */}
      <div className="bg-white border rounded-xl p-5 space-y-4 mb-4">
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-xs font-medium text-gray-600 mb-1">Topic</label>
            {topics.length === 0 ? (
              <p className="text-sm text-gray-400">No topics available.</p>
            ) : (
              <select
                value={selectedTopic}
                onChange={e => setSelectedTopic(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg text-sm"
              >
                {topics.map(t => (
                  <option key={t.name} value={t.name}>{t.name} ({t.partitions}P / {t.replication_factor}R)</option>
                ))}
              </select>
            )}
          </div>
          <div>
            <label className="block text-xs font-medium text-gray-600 mb-1">Max Messages</label>
            <input
              type="number"
              min={1}
              max={100}
              value={maxMessages}
              onChange={e => setMaxMessages(Number(e.target.value))}
              className="w-full px-3 py-2 border rounded-lg text-sm"
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4">
          <div>
            <label className="block text-xs font-medium text-gray-600 mb-1">Consumer Group ID (optional)</label>
            <input
              type="text"
              value={groupId}
              onChange={e => setGroupId(e.target.value)}
              placeholder="my-consumer-group"
              className="w-full px-3 py-2 border rounded-lg text-sm font-mono"
            />
          </div>
          <div>
            <label className="block text-xs font-medium text-gray-600 mb-1">Timeout (ms)</label>
            <input
              type="number"
              min={1000}
              max={60000}
              step={1000}
              value={timeoutMs}
              onChange={e => setTimeoutMs(Number(e.target.value))}
              className="w-full px-3 py-2 border rounded-lg text-sm"
            />
          </div>
          <div className="flex items-end">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={fromBeginning}
                onChange={e => setFromBeginning(e.target.checked)}
                className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
              />
              <span className="text-sm text-gray-700">From beginning</span>
            </label>
          </div>
        </div>

        <div className="flex items-center gap-3">
          <button
            onClick={handleConsume}
            disabled={consuming || !selectedTopic}
            className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 disabled:opacity-50"
          >
            {consuming ? <Loader2 size={15} className="animate-spin" /> : <Download size={15} />}
            Consume
          </button>
          {consuming && <span className="text-xs text-gray-400">Waiting for messages...</span>}
        </div>
      </div>

      {/* Error */}
      {error && (
        <div className="flex items-center gap-2 bg-yellow-50 border border-yellow-200 rounded-lg px-4 py-3 mb-4 text-sm text-yellow-700">
          <AlertCircle size={16} />
          <span>{error}</span>
        </div>
      )}

      {/* Results */}
      {messages.length > 0 && (
        <div>
          <div className="flex items-center justify-between mb-3">
            <h4 className="text-xs font-semibold text-gray-500 uppercase tracking-wider">
              {messages.length} Message{messages.length !== 1 ? 's' : ''} Consumed
            </h4>
          </div>

          <div className="space-y-2">
            {messages.map((msg, i) => (
              <div key={i} className="bg-white border rounded-lg overflow-hidden">
                {/* Message header with metadata */}
                <button
                  onClick={() => setExpandedMsg(expandedMsg === i ? null : i)}
                  className="w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-gray-50 transition-colors"
                >
                  <span className="text-xs font-mono text-gray-400 w-6">#{i + 1}</span>

                  {msg.partition !== null && (
                    <span className="flex items-center gap-1 text-xs text-purple-600 bg-purple-50 px-2 py-0.5 rounded">
                      <Hash size={10} /> P{msg.partition}
                    </span>
                  )}
                  {msg.offset !== null && (
                    <span className="text-xs text-gray-500 bg-gray-100 px-2 py-0.5 rounded font-mono">
                      offset: {msg.offset}
                    </span>
                  )}
                  {msg.timestamp !== null && (
                    <span className="flex items-center gap-1 text-xs text-gray-400">
                      <Clock size={10} /> {formatTimestamp(msg.timestamp)}
                    </span>
                  )}
                  {msg.key && (
                    <span className="flex items-center gap-1 text-xs text-orange-600 bg-orange-50 px-2 py-0.5 rounded">
                      <Key size={10} /> {msg.key}
                    </span>
                  )}

                  <span className="ml-auto text-xs text-gray-400 truncate max-w-xs font-mono">
                    {msg.value.substring(0, 80)}{msg.value.length > 80 ? '...' : ''}
                  </span>
                </button>

                {/* Expanded message body */}
                {expandedMsg === i && (
                  <div className="border-t bg-gray-50 p-4 space-y-3">
                    <div className="grid grid-cols-4 gap-3 text-xs">
                      <div>
                        <span className="text-gray-500 block">Partition</span>
                        <span className="font-mono font-medium">{msg.partition ?? '-'}</span>
                      </div>
                      <div>
                        <span className="text-gray-500 block">Offset</span>
                        <span className="font-mono font-medium">{msg.offset ?? '-'}</span>
                      </div>
                      <div>
                        <span className="text-gray-500 block">Timestamp</span>
                        <span className="font-mono font-medium">{formatTimestamp(msg.timestamp)}</span>
                      </div>
                      <div>
                        <span className="text-gray-500 block">Key</span>
                        <span className="font-mono font-medium">{msg.key || '(null)'}</span>
                      </div>
                    </div>
                    {msg.headers && (
                      <div>
                        <span className="text-xs text-gray-500 block mb-1">Headers</span>
                        <pre className="text-xs bg-white border rounded p-2 font-mono text-gray-700 overflow-x-auto">
                          {msg.headers}
                        </pre>
                      </div>
                    )}
                    <div>
                      <span className="text-xs text-gray-500 block mb-1">Value</span>
                      <pre className="text-xs bg-gray-900 text-green-400 rounded p-3 font-mono overflow-x-auto max-h-48 overflow-y-auto">
                        {(() => {
                          try {
                            return JSON.stringify(JSON.parse(msg.value), null, 2);
                          } catch {
                            return msg.value;
                          }
                        })()}
                      </pre>
                    </div>
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
