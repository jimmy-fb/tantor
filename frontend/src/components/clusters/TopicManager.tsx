import { useState, useEffect, useCallback } from 'react';
import { Plus, Trash2, RefreshCw, ChevronDown, ChevronUp, Loader2, Search, AlertCircle } from 'lucide-react';
import type { TopicInfo, TopicDetail } from '../../types';
import { getTopics, getTopic, createTopic, deleteTopic } from '../../lib/api';

interface Props {
  clusterId: string;
}

export default function TopicManager({ clusterId }: Props) {
  const [topics, setTopics] = useState<TopicInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [expandedDetail, setExpandedDetail] = useState<TopicDetail | null>(null);
  const [creating, setCreating] = useState(false);
  const [deleting, setDeleting] = useState<string | null>(null);
  const [search, setSearch] = useState('');

  // Create form state
  const [newName, setNewName] = useState('');
  const [newPartitions, setNewPartitions] = useState(3);
  const [newRF, setNewRF] = useState(1);

  const fetchTopics = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await getTopics(clusterId, search || undefined);
      setTopics(data);
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail;
      setError(msg || 'Failed to load topics. Is the broker reachable?');
      setTopics([]);
    } finally {
      setLoading(false);
    }
  }, [clusterId, search]);

  useEffect(() => {
    fetchTopics();
  }, [fetchTopics]);

  // Auto-refresh every 15 seconds
  useEffect(() => {
    const interval = setInterval(fetchTopics, 15000);
    return () => clearInterval(interval);
  }, [fetchTopics]);

  const handleExpand = async (name: string) => {
    if (expanded === name) {
      setExpanded(null);
      setExpandedDetail(null);
      return;
    }
    setExpanded(name);
    try {
      const detail = await getTopic(clusterId, name);
      setExpandedDetail(detail);
    } catch {
      setExpandedDetail(null);
    }
  };

  const handleCreate = async () => {
    if (!newName.trim()) return;
    setCreating(true);
    try {
      await createTopic(clusterId, {
        name: newName.trim(),
        partitions: newPartitions,
        replication_factor: newRF,
      });
      setNewName('');
      setNewPartitions(3);
      setNewRF(1);
      setShowCreate(false);
      fetchTopics();
    } finally {
      setCreating(false);
    }
  };

  const handleDelete = async (name: string) => {
    if (!confirm(`Delete topic "${name}"? This cannot be undone.`)) return;
    setDeleting(name);
    try {
      await deleteTopic(clusterId, name);
      fetchTopics();
    } finally {
      setDeleting(null);
    }
  };

  return (
    <div>
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-gray-700">Topics ({topics.length})</h3>
        <div className="flex gap-2">
          {/* Search */}
          <div className="relative">
            <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-gray-400" />
            <input
              type="text"
              value={search}
              onChange={e => setSearch(e.target.value)}
              placeholder="Search topics..."
              className="pl-8 pr-3 py-1.5 text-xs border rounded-lg w-48 focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <button
            onClick={fetchTopics}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs border rounded-lg hover:bg-gray-50"
          >
            <RefreshCw size={13} /> Refresh
          </button>
          <button
            onClick={() => setShowCreate(!showCreate)}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs bg-blue-600 text-white rounded-lg hover:bg-blue-700"
          >
            <Plus size={13} /> Create Topic
          </button>
        </div>
      </div>

      {/* Error banner */}
      {error && (
        <div className="flex items-center gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mb-4 text-sm text-red-700">
          <AlertCircle size={16} />
          <span>{error}</span>
          <button onClick={fetchTopics} className="ml-auto text-xs underline hover:no-underline">Retry</button>
        </div>
      )}

      {/* Create form */}
      {showCreate && (
        <div className="bg-blue-50 border border-blue-200 rounded-xl p-4 mb-4">
          <h4 className="text-sm font-medium text-gray-800 mb-3">Create New Topic</h4>
          <div className="grid grid-cols-3 gap-3">
            <div>
              <label className="block text-xs text-gray-600 mb-1">Topic Name</label>
              <input
                type="text"
                value={newName}
                onChange={e => setNewName(e.target.value)}
                placeholder="my-topic"
                className="w-full px-2.5 py-1.5 border rounded-lg text-sm"
              />
            </div>
            <div>
              <label className="block text-xs text-gray-600 mb-1">Partitions</label>
              <input
                type="number"
                min={1}
                value={newPartitions}
                onChange={e => setNewPartitions(Number(e.target.value))}
                className="w-full px-2.5 py-1.5 border rounded-lg text-sm"
              />
            </div>
            <div>
              <label className="block text-xs text-gray-600 mb-1">Replication Factor</label>
              <input
                type="number"
                min={1}
                value={newRF}
                onChange={e => setNewRF(Number(e.target.value))}
                className="w-full px-2.5 py-1.5 border rounded-lg text-sm"
              />
            </div>
          </div>
          <div className="flex gap-2 mt-3">
            <button
              onClick={handleCreate}
              disabled={creating || !newName.trim()}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50"
            >
              {creating ? <Loader2 size={13} className="animate-spin" /> : null}
              Create
            </button>
            <button
              onClick={() => setShowCreate(false)}
              className="px-3 py-1.5 text-xs border rounded-lg hover:bg-gray-50"
            >
              Cancel
            </button>
          </div>
        </div>
      )}

      {loading ? (
        <div className="flex items-center justify-center gap-2 py-8 text-gray-400 text-sm">
          <Loader2 size={16} className="animate-spin" /> Loading topics...
        </div>
      ) : topics.length === 0 && !error ? (
        <div className="text-center py-8 text-gray-400 text-sm">
          {search ? `No topics matching "${search}"` : 'No topics found. Create one to get started.'}
        </div>
      ) : (
        <div className="bg-white border rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-gray-500 bg-gray-50">
                <th className="px-4 py-2.5 font-medium">Name</th>
                <th className="px-4 py-2.5 font-medium">Partitions</th>
                <th className="px-4 py-2.5 font-medium">Replication</th>
                <th className="px-4 py-2.5 font-medium w-20"></th>
              </tr>
            </thead>
            <tbody>
              {topics.map(topic => (
                <TopicRow
                  key={topic.name}
                  topic={topic}
                  expanded={expanded === topic.name}
                  expandedDetail={expanded === topic.name ? expandedDetail : null}
                  deleting={deleting === topic.name}
                  onExpand={() => handleExpand(topic.name)}
                  onDelete={() => handleDelete(topic.name)}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function TopicRow({
  topic, expanded, expandedDetail, deleting, onExpand, onDelete,
}: {
  topic: TopicInfo;
  expanded: boolean;
  expandedDetail: TopicDetail | null;
  deleting: boolean;
  onExpand: () => void;
  onDelete: () => void;
}) {
  return (
    <>
      <tr className="border-b last:border-0 hover:bg-gray-50 cursor-pointer" onClick={onExpand}>
        <td className="px-4 py-2.5 font-mono text-gray-900">{topic.name}</td>
        <td className="px-4 py-2.5 text-gray-600">{topic.partitions}</td>
        <td className="px-4 py-2.5 text-gray-600">{topic.replication_factor}</td>
        <td className="px-4 py-2.5">
          <div className="flex items-center gap-2">
            <button
              onClick={e => { e.stopPropagation(); onDelete(); }}
              disabled={deleting}
              className="p-1 text-gray-400 hover:text-red-600 rounded"
            >
              {deleting ? <Loader2 size={14} className="animate-spin" /> : <Trash2 size={14} />}
            </button>
            {expanded ? <ChevronUp size={14} className="text-gray-400" /> : <ChevronDown size={14} className="text-gray-400" />}
          </div>
        </td>
      </tr>
      {expanded && expandedDetail && (
        <tr>
          <td colSpan={4} className="bg-gray-50 px-4 py-3">
            <div className="text-xs text-gray-600 space-y-3">
              {/* Configs */}
              {expandedDetail.configs && Object.keys(expandedDetail.configs).length > 0 && (
                <div>
                  <h5 className="font-semibold text-gray-700 mb-1">Configuration</h5>
                  <div className="grid grid-cols-2 gap-1 font-mono">
                    {Object.entries(expandedDetail.configs).map(([k, v]) => (
                      <div key={k}><span className="text-gray-500">{k}=</span>{v}</div>
                    ))}
                  </div>
                </div>
              )}
              {/* Partition details */}
              <div>
                <h5 className="font-semibold text-gray-700 mb-1">Partition Details</h5>
                <table className="w-full">
                  <thead>
                    <tr className="text-left text-gray-500">
                      <th className="pr-4 pb-1 font-medium">Partition</th>
                      <th className="pr-4 pb-1 font-medium">Leader</th>
                      <th className="pr-4 pb-1 font-medium">Replicas</th>
                      <th className="pr-4 pb-1 font-medium">ISR</th>
                    </tr>
                  </thead>
                  <tbody>
                    {expandedDetail.partition_details.map((p, i) => (
                      <tr key={i} className="font-mono">
                        <td className="pr-4 py-0.5">{String(p.partition ?? i)}</td>
                        <td className="pr-4 py-0.5">{String(p.leader ?? '-')}</td>
                        <td className="pr-4 py-0.5">{Array.isArray(p.replicas) ? (p.replicas as number[]).join(', ') : String(p.replicas ?? '-')}</td>
                        <td className="pr-4 py-0.5">{Array.isArray(p.isr) ? (p.isr as number[]).join(', ') : String(p.isr ?? '-')}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}
