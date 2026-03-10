import { useState, useEffect, useCallback, useRef } from 'react';
import {
  Play, Square, RefreshCw, Loader2, Trash2, Save, Database,
  Clock, List, ChevronDown, ChevronRight, AlertCircle, CheckCircle,
  Copy, Terminal,
} from 'lucide-react';
import type {
  KsqlExecuteResponse, KsqlServerInfo, KsqlEntity,
  KsqlStreamPollResponse, KsqlQueryHistory,
} from '../../types';
import {
  getKsqlStatus, executeKsql, startKsqlStream, pollKsqlStream,
  stopKsqlStream, getKsqlEntities, getKsqlHistory, saveKsqlQuery,
  deleteKsqlHistory,
} from '../../lib/api';

type SubTab = 'editor' | 'entities' | 'history';

export default function KsqlManager({ clusterId }: { clusterId: string }) {
  const [subTab, setSubTab] = useState<SubTab>('editor');
  const [serverInfo, setServerInfo] = useState<KsqlServerInfo | null>(null);
  const [serverError, setServerError] = useState<string | null>(null);

  // Editor state
  const [sql, setSql] = useState('');
  const [executing, setExecuting] = useState(false);
  const [result, setResult] = useState<KsqlExecuteResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Streaming state
  const [streamId, setStreamId] = useState<string | null>(null);
  const [streamColumns, setStreamColumns] = useState<string[]>([]);
  const [streamRows, setStreamRows] = useState<unknown[][]>([]);
  const [streamStatus, setStreamStatus] = useState<string | null>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Entities state
  const [entities, setEntities] = useState<{ streams: KsqlEntity[]; tables: KsqlEntity[] }>({ streams: [], tables: [] });
  const [entitiesLoading, setEntitiesLoading] = useState(false);

  // History state
  const [history, setHistory] = useState<KsqlQueryHistory[]>([]);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [saveName, setSaveName] = useState('');
  const [showSaveForm, setShowSaveForm] = useState(false);

  // Fetch server info on mount
  useEffect(() => {
    getKsqlStatus(clusterId)
      .then(info => { setServerInfo(info); setServerError(null); })
      .catch(err => {
        setServerError(err?.response?.data?.detail || 'Cannot connect to ksqlDB');
      });
  }, [clusterId]);

  // Cleanup polling on unmount
  useEffect(() => {
    return () => {
      if (pollRef.current) clearInterval(pollRef.current);
    };
  }, []);

  // ── Execute SQL ────────────────────────────────────

  const handleExecute = useCallback(async () => {
    if (!sql.trim()) return;
    setExecuting(true);
    setResult(null);
    setError(null);
    setStreamId(null);
    setStreamRows([]);
    setStreamColumns([]);
    setStreamStatus(null);
    if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }

    const sqlUpper = sql.trim().toUpperCase();
    const isPush = sqlUpper.includes('EMIT CHANGES') || sqlUpper.includes('EMIT FINAL');

    try {
      if (isPush) {
        // Start streaming push query
        const resp = await startKsqlStream(clusterId, sql);
        setStreamId(resp.stream_id);
        setStreamStatus('running');
        setExecuting(false);

        // Start polling
        pollRef.current = setInterval(async () => {
          try {
            const poll: KsqlStreamPollResponse = await pollKsqlStream(clusterId, resp.stream_id);
            if (poll.columns.length > 0) setStreamColumns(poll.columns);
            if (poll.rows.length > 0) {
              setStreamRows(prev => [...prev, ...poll.rows]);
            }
            if (poll.done) {
              setStreamStatus(poll.status);
              if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
            }
          } catch {
            setStreamStatus('error');
            if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
          }
        }, 1500);
      } else {
        // Execute normal statement/query
        const resp = await executeKsql(clusterId, sql);
        setResult(resp);
        setExecuting(false);
      }
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail;
      setError(msg || 'Execution failed');
      setExecuting(false);
    }
  }, [clusterId, sql]);

  const handleStopStream = useCallback(async () => {
    if (!streamId) return;
    try {
      await stopKsqlStream(clusterId, streamId);
      setStreamStatus('stopped');
      if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
    } catch {
      // Best effort
    }
  }, [clusterId, streamId]);

  // ── Entities ──────────────────────────────────────

  const fetchEntities = useCallback(async () => {
    setEntitiesLoading(true);
    try {
      const data = await getKsqlEntities(clusterId);
      setEntities(data);
    } catch {
      setEntities({ streams: [], tables: [] });
    } finally {
      setEntitiesLoading(false);
    }
  }, [clusterId]);

  useEffect(() => {
    if (subTab === 'entities') fetchEntities();
  }, [subTab, fetchEntities]);

  // ── History ───────────────────────────────────────

  const fetchHistory = useCallback(async () => {
    setHistoryLoading(true);
    try {
      const data = await getKsqlHistory(clusterId);
      setHistory(data);
    } catch {
      setHistory([]);
    } finally {
      setHistoryLoading(false);
    }
  }, [clusterId]);

  useEffect(() => {
    if (subTab === 'history') fetchHistory();
  }, [subTab, fetchHistory]);

  const handleSaveQuery = async () => {
    if (!saveName.trim() || !sql.trim()) return;
    try {
      await saveKsqlQuery(clusterId, sql, saveName);
      setSaveName('');
      setShowSaveForm(false);
      fetchHistory();
    } catch {
      // ignore
    }
  };

  const handleDeleteHistory = async (id: string) => {
    try {
      await deleteKsqlHistory(clusterId, id);
      setHistory(prev => prev.filter(h => h.id !== id));
    } catch {
      // ignore
    }
  };

  const handleLoadFromHistory = (entry: KsqlQueryHistory) => {
    setSql(entry.sql);
    setSubTab('editor');
  };

  const handleDescribeEntity = (name: string) => {
    setSql(`DESCRIBE ${name};`);
    setSubTab('editor');
  };

  // ── Keyboard shortcut ─────────────────────────────

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
      e.preventDefault();
      handleExecute();
    }
  };

  const isStreaming = streamStatus === 'running';

  return (
    <div>
      {/* Status bar */}
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-3">
          <div className="flex items-center gap-2">
            <Database size={16} className="text-orange-500" />
            <span className="text-sm font-semibold text-gray-700">ksqlDB SQL Console</span>
          </div>
          {serverInfo ? (
            <div className="flex items-center gap-1.5 text-xs">
              <span className="w-2 h-2 rounded-full bg-green-500" />
              <span className="text-gray-500">v{serverInfo.version}</span>
              <span className="text-gray-300">|</span>
              <span className="text-gray-400">{serverInfo.ksqlServiceId}</span>
            </div>
          ) : serverError ? (
            <div className="flex items-center gap-1.5 text-xs text-red-500">
              <span className="w-2 h-2 rounded-full bg-red-500" />
              {serverError}
            </div>
          ) : (
            <div className="flex items-center gap-1.5 text-xs text-gray-400">
              <Loader2 size={12} className="animate-spin" /> Connecting...
            </div>
          )}
        </div>
      </div>

      {/* Sub-tabs */}
      <div className="flex gap-1 mb-4 border-b">
        {([
          { id: 'editor' as SubTab, label: 'Editor', icon: <Terminal size={13} /> },
          { id: 'entities' as SubTab, label: 'Entities', icon: <List size={13} /> },
          { id: 'history' as SubTab, label: 'History', icon: <Clock size={13} /> },
        ]).map(tab => (
          <button
            key={tab.id}
            onClick={() => setSubTab(tab.id)}
            className={`flex items-center gap-1.5 px-3 py-2 text-sm font-medium border-b-2 transition-colors ${
              subTab === tab.id
                ? 'border-orange-500 text-orange-600'
                : 'border-transparent text-gray-500 hover:text-gray-700'
            }`}
          >
            {tab.icon} {tab.label}
          </button>
        ))}
      </div>

      {/* ── Editor Tab ──────────────────────────────── */}
      {subTab === 'editor' && (
        <div>
          {/* SQL Editor */}
          <div className="mb-3">
            <textarea
              value={sql}
              onChange={e => setSql(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Enter ksqlDB SQL statement... (Ctrl+Enter to execute)"
              rows={6}
              className="w-full px-4 py-3 bg-gray-900 text-green-400 font-mono text-sm border border-gray-700 rounded-xl focus:ring-2 focus:ring-orange-500 focus:border-transparent placeholder-gray-600 resize-y"
            />
          </div>

          {/* Action bar */}
          <div className="flex items-center gap-2 mb-4">
            {!isStreaming ? (
              <button
                onClick={handleExecute}
                disabled={executing || !sql.trim() || !serverInfo}
                className="flex items-center gap-1.5 px-4 py-2 bg-orange-600 text-white text-sm rounded-lg hover:bg-orange-700 disabled:opacity-50"
              >
                {executing ? <Loader2 size={14} className="animate-spin" /> : <Play size={14} />}
                Execute
              </button>
            ) : (
              <button
                onClick={handleStopStream}
                className="flex items-center gap-1.5 px-4 py-2 bg-red-600 text-white text-sm rounded-lg hover:bg-red-700"
              >
                <Square size={14} /> Stop
              </button>
            )}
            <button
              onClick={() => { setSql(''); setResult(null); setError(null); setStreamRows([]); setStreamColumns([]); setStreamStatus(null); }}
              className="flex items-center gap-1.5 px-3 py-2 border text-sm rounded-lg hover:bg-gray-50 text-gray-600"
            >
              Clear
            </button>
            <button
              onClick={() => setShowSaveForm(!showSaveForm)}
              disabled={!sql.trim()}
              className="flex items-center gap-1.5 px-3 py-2 border text-sm rounded-lg hover:bg-gray-50 text-gray-600 disabled:opacity-50"
            >
              <Save size={14} /> Save
            </button>
            {isStreaming && (
              <span className="flex items-center gap-1.5 text-xs text-orange-600 ml-2">
                <span className="w-2 h-2 rounded-full bg-orange-500 animate-pulse" />
                Streaming... ({streamRows.length} rows)
              </span>
            )}
          </div>

          {/* Save form */}
          {showSaveForm && (
            <div className="flex items-center gap-2 mb-4 bg-blue-50 border border-blue-200 rounded-lg px-3 py-2">
              <input
                type="text"
                value={saveName}
                onChange={e => setSaveName(e.target.value)}
                placeholder="Query name..."
                className="flex-1 px-2 py-1 border rounded text-sm"
              />
              <button
                onClick={handleSaveQuery}
                disabled={!saveName.trim()}
                className="px-3 py-1 bg-blue-600 text-white text-xs rounded hover:bg-blue-700 disabled:opacity-50"
              >
                Save
              </button>
              <button
                onClick={() => setShowSaveForm(false)}
                className="px-2 py-1 text-xs text-gray-500 hover:text-gray-700"
              >
                Cancel
              </button>
            </div>
          )}

          {/* Error display */}
          {error && (
            <div className="flex items-start gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mb-4 text-sm text-red-700">
              <AlertCircle size={16} className="mt-0.5 shrink-0" />
              <pre className="whitespace-pre-wrap font-mono text-xs">{error}</pre>
            </div>
          )}

          {/* Statement result */}
          {result && result.type === 'statement' && (
            <div className={`flex items-start gap-2 rounded-lg px-4 py-3 mb-4 text-sm border ${
              result.status === 'ERROR' ? 'bg-red-50 border-red-200 text-red-700' : 'bg-green-50 border-green-200 text-green-700'
            }`}>
              {result.status === 'ERROR' ? <AlertCircle size={16} className="mt-0.5 shrink-0" /> : <CheckCircle size={16} className="mt-0.5 shrink-0" />}
              <div>
                <p className="font-medium">{result.message}</p>
                {result.statementText && (
                  <p className="text-xs mt-1 opacity-70 font-mono">{result.statementText}</p>
                )}
              </div>
            </div>
          )}

          {/* Error result */}
          {result && result.type === 'error' && (
            <div className="flex items-start gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mb-4 text-sm text-red-700">
              <AlertCircle size={16} className="mt-0.5 shrink-0" />
              <pre className="whitespace-pre-wrap font-mono text-xs">{result.message}</pre>
            </div>
          )}

          {/* Entity list result (SHOW/DESCRIBE) */}
          {result && result.entities && Array.isArray(result.entities) && (
            <div className="bg-white border rounded-xl overflow-hidden mb-4">
              <div className="px-4 py-2 bg-gray-50 border-b text-xs text-gray-500 font-medium">
                Results ({result.entities.length})
              </div>
              <div className="max-h-80 overflow-auto">
                <pre className="px-4 py-3 text-xs font-mono text-gray-700 whitespace-pre-wrap">
                  {JSON.stringify(result.entities, null, 2)}
                </pre>
              </div>
            </div>
          )}

          {/* Query result table */}
          {result && result.type === 'query' && result.columns && result.rows && (
            <ResultTable columns={result.columns} rows={result.rows} label={`${result.row_count || result.rows.length} row(s)`} />
          )}

          {/* Streaming result table */}
          {(streamColumns.length > 0 || streamRows.length > 0) && (
            <ResultTable
              columns={streamColumns}
              rows={streamRows}
              label={`${streamRows.length} row(s)${isStreaming ? ' (streaming)' : ''}`}
              streaming={isStreaming}
            />
          )}
        </div>
      )}

      {/* ── Entities Tab ────────────────────────────── */}
      {subTab === 'entities' && (
        <div>
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-sm font-semibold text-gray-700">Streams & Tables</h3>
            <button
              onClick={fetchEntities}
              disabled={entitiesLoading}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs border rounded-lg hover:bg-gray-50"
            >
              {entitiesLoading ? <Loader2 size={13} className="animate-spin" /> : <RefreshCw size={13} />}
              Refresh
            </button>
          </div>

          {/* Streams */}
          <div className="mb-6">
            <h4 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2">
              Streams ({entities.streams.length})
            </h4>
            {entities.streams.length === 0 ? (
              <p className="text-xs text-gray-400 py-3">No streams found</p>
            ) : (
              <div className="space-y-2">
                {entities.streams.map(s => (
                  <EntityCard key={s.name} entity={s} onDescribe={handleDescribeEntity} />
                ))}
              </div>
            )}
          </div>

          {/* Tables */}
          <div>
            <h4 className="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2">
              Tables ({entities.tables.length})
            </h4>
            {entities.tables.length === 0 ? (
              <p className="text-xs text-gray-400 py-3">No tables found</p>
            ) : (
              <div className="space-y-2">
                {entities.tables.map(t => (
                  <EntityCard key={t.name} entity={t} onDescribe={handleDescribeEntity} />
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      {/* ── History Tab ─────────────────────────────── */}
      {subTab === 'history' && (
        <div>
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-sm font-semibold text-gray-700">Query History</h3>
            <button
              onClick={fetchHistory}
              disabled={historyLoading}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs border rounded-lg hover:bg-gray-50"
            >
              {historyLoading ? <Loader2 size={13} className="animate-spin" /> : <RefreshCw size={13} />}
              Refresh
            </button>
          </div>

          {history.length === 0 ? (
            <div className="text-center py-12 text-gray-400 text-sm">
              No queries yet. Execute a query in the Editor tab.
            </div>
          ) : (
            <div className="space-y-2">
              {history.map(entry => (
                <HistoryEntry
                  key={entry.id}
                  entry={entry}
                  onLoad={handleLoadFromHistory}
                  onDelete={handleDeleteHistory}
                />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}


// ── Sub-components ──────────────────────────────────

function ResultTable({
  columns,
  rows,
  label,
  streaming = false,
}: {
  columns: string[];
  rows: unknown[][];
  label: string;
  streaming?: boolean;
}) {
  const [expanded, setExpanded] = useState(true);

  return (
    <div className="bg-white border rounded-xl overflow-hidden mb-4">
      <button
        onClick={() => setExpanded(!expanded)}
        className="w-full flex items-center justify-between px-4 py-2 bg-gray-50 border-b text-xs text-gray-500 font-medium hover:bg-gray-100"
      >
        <span className="flex items-center gap-2">
          {expanded ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
          {label}
          {streaming && <span className="w-1.5 h-1.5 rounded-full bg-orange-500 animate-pulse" />}
        </span>
        <button
          onClick={e => {
            e.stopPropagation();
            const text = [columns.join('\t'), ...rows.map(r => (r as string[]).join('\t'))].join('\n');
            navigator.clipboard.writeText(text);
          }}
          className="p-1 hover:bg-gray-200 rounded"
          title="Copy to clipboard"
        >
          <Copy size={12} />
        </button>
      </button>
      {expanded && (
        <div className="max-h-96 overflow-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b bg-gray-50">
                <th className="px-3 py-2 text-left text-gray-500 font-medium w-10">#</th>
                {columns.map((col, i) => (
                  <th key={i} className="px-3 py-2 text-left text-gray-600 font-semibold whitespace-nowrap">
                    {col}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((row, i) => (
                <tr key={i} className="border-b last:border-0 hover:bg-gray-50">
                  <td className="px-3 py-1.5 text-gray-400">{i + 1}</td>
                  {(row as unknown[]).map((cell, j) => (
                    <td key={j} className="px-3 py-1.5 text-gray-700 font-mono whitespace-nowrap">
                      {cell === null ? <span className="text-gray-300 italic">null</span> : String(cell)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}


function EntityCard({ entity, onDescribe }: { entity: KsqlEntity; onDescribe: (name: string) => void }) {
  return (
    <div className="flex items-center justify-between border rounded-lg px-4 py-3 hover:bg-gray-50">
      <div>
        <div className="flex items-center gap-2">
          <span className={`px-2 py-0.5 rounded text-xs font-medium ${
            entity.type === 'STREAM' ? 'bg-blue-100 text-blue-700' : 'bg-purple-100 text-purple-700'
          }`}>
            {entity.type}
          </span>
          <span className="text-sm font-medium text-gray-800">{entity.name}</span>
        </div>
        <div className="text-xs text-gray-400 mt-1">
          Topic: {entity.topic}
          {entity.valueFormat && <span className="ml-3">Format: {entity.valueFormat}</span>}
        </div>
      </div>
      <button
        onClick={() => onDescribe(entity.name)}
        className="text-xs text-blue-600 hover:text-blue-800 px-2 py-1 rounded hover:bg-blue-50"
      >
        DESCRIBE
      </button>
    </div>
  );
}


function HistoryEntry({
  entry,
  onLoad,
  onDelete,
}: {
  entry: KsqlQueryHistory;
  onLoad: (e: KsqlQueryHistory) => void;
  onDelete: (id: string) => void;
}) {
  return (
    <div className="flex items-start gap-3 border rounded-lg px-4 py-3 hover:bg-gray-50">
      <div className="flex-1 min-w-0 cursor-pointer" onClick={() => onLoad(entry)}>
        <div className="flex items-center gap-2 mb-1">
          {entry.name && (
            <span className="text-xs font-semibold text-blue-600 bg-blue-50 px-1.5 py-0.5 rounded">
              {entry.name}
            </span>
          )}
          <span className={`text-xs px-1.5 py-0.5 rounded ${
            entry.status === 'success' || entry.status === 'saved' ? 'bg-green-50 text-green-600' : 'bg-red-50 text-red-600'
          }`}>
            {entry.status}
          </span>
          <span className="text-xs text-gray-400">
            {new Date(entry.created_at).toLocaleString()}
          </span>
        </div>
        <pre className="text-xs font-mono text-gray-600 truncate">{entry.sql}</pre>
      </div>
      <button
        onClick={() => onDelete(entry.id)}
        className="p-1 text-gray-400 hover:text-red-600 rounded shrink-0"
      >
        <Trash2 size={13} />
      </button>
    </div>
  );
}
