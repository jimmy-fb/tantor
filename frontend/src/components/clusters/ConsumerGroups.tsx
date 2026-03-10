import { useState, useEffect } from 'react';
import { RefreshCw, ChevronDown, ChevronUp, Users } from 'lucide-react';
import type { ConsumerGroupInfo, ConsumerGroupDetail } from '../../types';
import { getConsumerGroups, getConsumerGroup } from '../../lib/api';

interface Props {
  clusterId: string;
}

const STATE_COLORS: Record<string, string> = {
  Stable: 'bg-green-100 text-green-700',
  Empty: 'bg-gray-100 text-gray-600',
  PreparingRebalance: 'bg-yellow-100 text-yellow-700',
  CompletingRebalance: 'bg-yellow-100 text-yellow-700',
  Dead: 'bg-red-100 text-red-700',
};

export default function ConsumerGroups({ clusterId }: Props) {
  const [groups, setGroups] = useState<ConsumerGroupInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [expandedDetail, setExpandedDetail] = useState<ConsumerGroupDetail | null>(null);

  const fetchGroups = async () => {
    setLoading(true);
    try {
      const data = await getConsumerGroups(clusterId);
      setGroups(data);
    } catch {
      setGroups([]);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchGroups();
  }, [clusterId]);

  const handleExpand = async (groupId: string) => {
    if (expanded === groupId) {
      setExpanded(null);
      setExpandedDetail(null);
      return;
    }
    setExpanded(groupId);
    try {
      const detail = await getConsumerGroup(clusterId, groupId);
      setExpandedDetail(detail);
    } catch {
      setExpandedDetail(null);
    }
  };

  return (
    <div>
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-gray-700">
          Consumer Groups ({groups.length})
        </h3>
        <button
          onClick={fetchGroups}
          className="flex items-center gap-1.5 px-3 py-1.5 text-xs border rounded-lg hover:bg-gray-50"
        >
          <RefreshCw size={13} /> Refresh
        </button>
      </div>

      {loading ? (
        <div className="text-center py-8 text-gray-400 text-sm">Loading consumer groups...</div>
      ) : groups.length === 0 ? (
        <div className="text-center py-8">
          <Users size={36} className="mx-auto text-gray-300 mb-2" />
          <p className="text-gray-400 text-sm">No consumer groups found.</p>
        </div>
      ) : (
        <div className="bg-white border rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-gray-500 bg-gray-50">
                <th className="px-4 py-2.5 font-medium">Group ID</th>
                <th className="px-4 py-2.5 font-medium">State</th>
                <th className="px-4 py-2.5 font-medium">Members</th>
                <th className="px-4 py-2.5 font-medium">Topics</th>
                <th className="px-4 py-2.5 font-medium w-10"></th>
              </tr>
            </thead>
            <tbody>
              {groups.map(group => (
                <>
                  <tr
                    key={group.group_id}
                    className="border-b last:border-0 hover:bg-gray-50 cursor-pointer"
                    onClick={() => handleExpand(group.group_id)}
                  >
                    <td className="px-4 py-2.5 font-mono text-gray-900">{group.group_id}</td>
                    <td className="px-4 py-2.5">
                      <span className={`px-2 py-0.5 rounded text-xs font-medium ${STATE_COLORS[group.state] || 'bg-gray-100 text-gray-600'}`}>
                        {group.state}
                      </span>
                    </td>
                    <td className="px-4 py-2.5 text-gray-600">{group.members}</td>
                    <td className="px-4 py-2.5 text-gray-600">{group.topics.join(', ')}</td>
                    <td className="px-4 py-2.5">
                      {expanded === group.group_id ? (
                        <ChevronUp size={14} className="text-gray-400" />
                      ) : (
                        <ChevronDown size={14} className="text-gray-400" />
                      )}
                    </td>
                  </tr>
                  {expanded === group.group_id && expandedDetail && (
                    <tr key={`${group.group_id}-detail`}>
                      <td colSpan={5} className="bg-gray-50 px-4 py-3">
                        <div className="text-xs text-gray-600">
                          <h5 className="font-semibold text-gray-700 mb-2">Partition Offsets &amp; Lag</h5>
                          {expandedDetail.offsets.length === 0 ? (
                            <p className="text-gray-400 italic">No offset data available.</p>
                          ) : (
                            <table className="w-full">
                              <thead>
                                <tr className="text-left text-gray-500">
                                  <th className="pr-4 pb-1 font-medium">Topic</th>
                                  <th className="pr-4 pb-1 font-medium">Partition</th>
                                  <th className="pr-4 pb-1 font-medium">Current Offset</th>
                                  <th className="pr-4 pb-1 font-medium">Log End Offset</th>
                                  <th className="pr-4 pb-1 font-medium">Lag</th>
                                </tr>
                              </thead>
                              <tbody>
                                {expandedDetail.offsets.map((o, i) => (
                                  <tr key={i} className="font-mono">
                                    <td className="pr-4 py-0.5">{String(o.topic ?? '-')}</td>
                                    <td className="pr-4 py-0.5">{String(o.partition ?? '-')}</td>
                                    <td className="pr-4 py-0.5">{String(o.current_offset ?? '-')}</td>
                                    <td className="pr-4 py-0.5">{String(o.log_end_offset ?? '-')}</td>
                                    <td className="pr-4 py-0.5">
                                      <span className={Number(o.lag) > 0 ? 'text-orange-600 font-semibold' : ''}>
                                        {String(o.lag ?? '-')}
                                      </span>
                                    </td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          )}
                        </div>
                      </td>
                    </tr>
                  )}
                </>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
