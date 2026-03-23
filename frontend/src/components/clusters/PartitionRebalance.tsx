import { useState, useEffect, useRef } from 'react';
import { Shuffle, Play, Check, RefreshCw, Loader2, AlertTriangle, CheckCircle, XCircle } from 'lucide-react';
import {
  getPartitionDistribution,
  generateReassignmentPlan,
  executeReassignment,
  verifyReassignment,
} from '../../lib/api';

interface BrokerInfo {
  broker_id: number;
  leader_count: number;
  replica_count: number;
}

interface PartitionInfo {
  partition: number;
  leader: number;
  replicas: number[];
  isr: number[];
}

interface TopicInfo {
  name: string;
  partitions: PartitionInfo[];
}

interface Distribution {
  brokers: BrokerInfo[];
  topics: TopicInfo[];
}

export default function PartitionRebalance({ clusterId }: { clusterId: string }) {
  // Distribution state
  const [distribution, setDistribution] = useState<Distribution | null>(null);
  const [loadingDist, setLoadingDist] = useState(false);
  const [distError, setDistError] = useState<string | null>(null);

  // Generate plan state
  const [selectedTopics, setSelectedTopics] = useState<Set<string>>(new Set());
  const [allTopicsSelected, setAllTopicsSelected] = useState(false);
  const [selectedBrokers, setSelectedBrokers] = useState<Set<number>>(new Set());
  const [generating, setGenerating] = useState(false);
  const [currentPlan, setCurrentPlan] = useState<Record<string, unknown> | null>(null);
  const [proposedPlan, setProposedPlan] = useState<Record<string, unknown> | null>(null);
  const [planError, setPlanError] = useState<string | null>(null);

  // Execute state
  const [executing, setExecuting] = useState(false);
  const [executeResult, setExecuteResult] = useState<string | null>(null);
  const [executeError, setExecuteError] = useState<string | null>(null);

  // Verify state
  const [verifying, setVerifying] = useState(false);
  const [verifyResult, setVerifyResult] = useState<{ complete: boolean; partitions: Array<{ partition: string; status: string }>; raw: string } | null>(null);
  const [verifyError, setVerifyError] = useState<string | null>(null);
  const verifyIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  // Confirmation
  const [showConfirm, setShowConfirm] = useState(false);

  useEffect(() => {
    loadDistribution();
    return () => {
      if (verifyIntervalRef.current) clearInterval(verifyIntervalRef.current);
    };
  }, [clusterId]);

  const loadDistribution = async () => {
    setLoadingDist(true);
    setDistError(null);
    try {
      const data = await getPartitionDistribution(clusterId);
      setDistribution(data);
      // Pre-select all brokers
      if (data.brokers) {
        setSelectedBrokers(new Set(data.brokers.map((b: BrokerInfo) => b.broker_id)));
      }
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Failed to load distribution';
      setDistError(msg);
    } finally {
      setLoadingDist(false);
    }
  };

  const handleToggleAllTopics = () => {
    if (!distribution) return;
    if (allTopicsSelected) {
      setSelectedTopics(new Set());
      setAllTopicsSelected(false);
    } else {
      setSelectedTopics(new Set(distribution.topics.map(t => t.name)));
      setAllTopicsSelected(true);
    }
  };

  const handleToggleTopic = (name: string) => {
    const next = new Set(selectedTopics);
    if (next.has(name)) {
      next.delete(name);
      setAllTopicsSelected(false);
    } else {
      next.add(name);
      if (distribution && next.size === distribution.topics.length) {
        setAllTopicsSelected(true);
      }
    }
    setSelectedTopics(next);
  };

  const handleToggleBroker = (id: number) => {
    const next = new Set(selectedBrokers);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setSelectedBrokers(next);
  };

  const handleGenerate = async () => {
    if (selectedTopics.size === 0 || selectedBrokers.size === 0) return;
    setGenerating(true);
    setPlanError(null);
    setCurrentPlan(null);
    setProposedPlan(null);
    setExecuteResult(null);
    setExecuteError(null);
    setVerifyResult(null);
    try {
      const result = await generateReassignmentPlan(clusterId, {
        topics: Array.from(selectedTopics),
        broker_ids: Array.from(selectedBrokers),
      });
      setCurrentPlan(result.current);
      setProposedPlan(result.proposed);
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Failed to generate plan';
      setPlanError(msg);
    } finally {
      setGenerating(false);
    }
  };

  const handleExecute = async () => {
    if (!proposedPlan) return;
    setShowConfirm(false);
    setExecuting(true);
    setExecuteError(null);
    setExecuteResult(null);
    try {
      const result = await executeReassignment(clusterId, { reassignment: proposedPlan });
      setExecuteResult(result.message || 'Reassignment started');
      // Start polling verification
      startVerifyPolling();
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Failed to execute reassignment';
      setExecuteError(msg);
    } finally {
      setExecuting(false);
    }
  };

  const startVerifyPolling = () => {
    if (verifyIntervalRef.current) clearInterval(verifyIntervalRef.current);
    // Immediate first check
    handleVerify();
    verifyIntervalRef.current = setInterval(() => {
      handleVerify();
    }, 5000);
  };

  const handleVerify = async () => {
    if (!proposedPlan) return;
    setVerifying(true);
    setVerifyError(null);
    try {
      const result = await verifyReassignment(clusterId, { reassignment: proposedPlan });
      setVerifyResult(result);
      if (result.complete && verifyIntervalRef.current) {
        clearInterval(verifyIntervalRef.current);
        verifyIntervalRef.current = null;
        // Reload distribution after completion
        loadDistribution();
      }
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { detail?: string } } })?.response?.data?.detail || 'Failed to verify reassignment';
      setVerifyError(msg);
      if (verifyIntervalRef.current) {
        clearInterval(verifyIntervalRef.current);
        verifyIntervalRef.current = null;
      }
    } finally {
      setVerifying(false);
    }
  };

  const maxReplicas = distribution
    ? Math.max(...distribution.brokers.map(b => b.replica_count), 1)
    : 1;
  const maxLeaders = distribution
    ? Math.max(...distribution.brokers.map(b => b.leader_count), 1)
    : 1;

  return (
    <div className="space-y-6">
      {/* Section 1: Current Distribution */}
      <div>
        <div className="flex items-center justify-between mb-4">
          <div>
            <h3 className="text-sm font-semibold text-gray-700">Partition Distribution</h3>
            <p className="text-xs text-gray-500 mt-1">
              Current leader and replica distribution across brokers
            </p>
          </div>
          <button
            onClick={loadDistribution}
            disabled={loadingDist}
            className="flex items-center gap-2 px-3 py-1.5 text-xs border rounded-lg hover:bg-gray-50 disabled:opacity-50"
          >
            {loadingDist ? <Loader2 size={13} className="animate-spin" /> : <RefreshCw size={13} />}
            Refresh
          </button>
        </div>

        {distError && (
          <div className="flex items-center gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mb-4 text-sm text-red-700">
            <AlertTriangle size={16} className="shrink-0" /> {distError}
          </div>
        )}

        {loadingDist && !distribution && (
          <div className="flex items-center justify-center gap-2 py-8 text-gray-400 text-sm">
            <Loader2 size={16} className="animate-spin" /> Loading distribution...
          </div>
        )}

        {distribution && distribution.brokers.length > 0 && (
          <div className="bg-white border rounded-xl overflow-hidden">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b text-left text-gray-500 bg-gray-50">
                  <th className="px-5 py-3 font-medium">Broker ID</th>
                  <th className="px-5 py-3 font-medium">Leaders</th>
                  <th className="px-5 py-3 font-medium">Leader Distribution</th>
                  <th className="px-5 py-3 font-medium">Replicas</th>
                  <th className="px-5 py-3 font-medium">Replica Distribution</th>
                </tr>
              </thead>
              <tbody>
                {distribution.brokers.map(broker => (
                  <tr key={broker.broker_id} className="border-b last:border-0">
                    <td className="px-5 py-3 font-medium text-gray-800">
                      Broker {broker.broker_id}
                    </td>
                    <td className="px-5 py-3 text-gray-600">{broker.leader_count}</td>
                    <td className="px-5 py-3">
                      <div className="flex items-center gap-2">
                        <div className="flex-1 bg-gray-100 rounded-full h-2.5 max-w-[200px]">
                          <div
                            className="bg-blue-500 h-2.5 rounded-full transition-all"
                            style={{ width: `${(broker.leader_count / maxLeaders) * 100}%` }}
                          />
                        </div>
                      </div>
                    </td>
                    <td className="px-5 py-3 text-gray-600">{broker.replica_count}</td>
                    <td className="px-5 py-3">
                      <div className="flex items-center gap-2">
                        <div className="flex-1 bg-gray-100 rounded-full h-2.5 max-w-[200px]">
                          <div
                            className="bg-green-500 h-2.5 rounded-full transition-all"
                            style={{ width: `${(broker.replica_count / maxReplicas) * 100}%` }}
                          />
                        </div>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {distribution && distribution.brokers.length === 0 && (
          <div className="text-center py-8 text-gray-400 text-sm">
            No brokers found. Is the cluster running?
          </div>
        )}
      </div>

      {/* Section 2: Generate Plan */}
      {distribution && distribution.topics.length > 0 && (
        <div>
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Generate Reassignment Plan</h3>
          <div className="bg-white border rounded-xl p-5">
            <div className="grid grid-cols-2 gap-6">
              {/* Topic Selection */}
              <div>
                <label className="block text-xs font-medium text-gray-600 mb-2">
                  Topics to Rebalance
                </label>
                <div className="border rounded-lg max-h-48 overflow-y-auto">
                  <label className="flex items-center gap-2 px-3 py-2 border-b bg-gray-50 cursor-pointer hover:bg-gray-100">
                    <input
                      type="checkbox"
                      checked={allTopicsSelected}
                      onChange={handleToggleAllTopics}
                      className="rounded border-gray-300 text-blue-600"
                    />
                    <span className="text-xs font-medium text-gray-700">All Topics ({distribution.topics.length})</span>
                  </label>
                  {distribution.topics.map(topic => (
                    <label
                      key={topic.name}
                      className="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:bg-gray-50"
                    >
                      <input
                        type="checkbox"
                        checked={selectedTopics.has(topic.name)}
                        onChange={() => handleToggleTopic(topic.name)}
                        className="rounded border-gray-300 text-blue-600"
                      />
                      <span className="text-xs text-gray-700 truncate">{topic.name}</span>
                      <span className="text-xs text-gray-400 ml-auto">{topic.partitions.length}p</span>
                    </label>
                  ))}
                </div>
              </div>

              {/* Broker Selection */}
              <div>
                <label className="block text-xs font-medium text-gray-600 mb-2">
                  Target Brokers
                </label>
                <div className="border rounded-lg">
                  {distribution.brokers.map(broker => (
                    <label
                      key={broker.broker_id}
                      className="flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-gray-50 border-b last:border-0"
                    >
                      <input
                        type="checkbox"
                        checked={selectedBrokers.has(broker.broker_id)}
                        onChange={() => handleToggleBroker(broker.broker_id)}
                        className="rounded border-gray-300 text-blue-600"
                      />
                      <span className="text-xs text-gray-700">
                        Broker {broker.broker_id}
                      </span>
                      <span className="text-xs text-gray-400 ml-auto">
                        {broker.leader_count}L / {broker.replica_count}R
                      </span>
                    </label>
                  ))}
                </div>
              </div>
            </div>

            <div className="mt-4 flex items-center gap-3">
              <button
                onClick={handleGenerate}
                disabled={generating || selectedTopics.size === 0 || selectedBrokers.size === 0}
                className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700 disabled:opacity-50"
              >
                {generating ? <Loader2 size={16} className="animate-spin" /> : <Shuffle size={16} />}
                Generate Plan
              </button>
              {selectedTopics.size === 0 && (
                <span className="text-xs text-gray-400">Select at least one topic</span>
              )}
            </div>

            {planError && (
              <div className="flex items-center gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mt-4 text-sm text-red-700">
                <AlertTriangle size={16} className="shrink-0" /> {planError}
              </div>
            )}
          </div>

          {/* Plan Diff View */}
          {proposedPlan && (
            <div className="mt-4 space-y-4">
              <h4 className="text-sm font-medium text-gray-700">Reassignment Plan</h4>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <div className="text-xs font-medium text-gray-500 mb-1">Current Assignment</div>
                  <pre className="bg-red-50 border border-red-200 rounded-lg p-4 text-xs font-mono overflow-x-auto max-h-64 overflow-y-auto text-red-800">
                    {JSON.stringify(currentPlan, null, 2)}
                  </pre>
                </div>
                <div>
                  <div className="text-xs font-medium text-gray-500 mb-1">Proposed Assignment</div>
                  <pre className="bg-green-50 border border-green-200 rounded-lg p-4 text-xs font-mono overflow-x-auto max-h-64 overflow-y-auto text-green-800">
                    {JSON.stringify(proposedPlan, null, 2)}
                  </pre>
                </div>
              </div>
            </div>
          )}
        </div>
      )}

      {/* Section 3: Execute */}
      {proposedPlan && (
        <div>
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Execute Reassignment</h3>
          <div className="bg-white border rounded-xl p-5">
            {!showConfirm ? (
              <button
                onClick={() => setShowConfirm(true)}
                disabled={executing}
                className="flex items-center gap-2 px-4 py-2 bg-orange-600 text-white text-sm rounded-lg hover:bg-orange-700 disabled:opacity-50"
              >
                {executing ? <Loader2 size={16} className="animate-spin" /> : <Play size={16} />}
                Execute Reassignment
              </button>
            ) : (
              <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
                <div className="flex items-start gap-2 mb-3">
                  <AlertTriangle size={16} className="text-yellow-600 mt-0.5 shrink-0" />
                  <div>
                    <p className="text-sm font-medium text-yellow-800">Confirm Partition Reassignment</p>
                    <p className="text-xs text-yellow-700 mt-1">
                      This will move partition replicas between brokers. The operation may cause
                      increased network traffic and temporary performance impact.
                    </p>
                  </div>
                </div>
                <div className="flex gap-2">
                  <button
                    onClick={handleExecute}
                    disabled={executing}
                    className="flex items-center gap-2 px-3 py-1.5 bg-orange-600 text-white text-xs rounded-lg hover:bg-orange-700 disabled:opacity-50"
                  >
                    {executing ? <Loader2 size={14} className="animate-spin" /> : <Check size={14} />}
                    Confirm & Execute
                  </button>
                  <button
                    onClick={() => setShowConfirm(false)}
                    className="px-3 py-1.5 text-xs border rounded-lg hover:bg-gray-50"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            )}

            {executeError && (
              <div className="flex items-center gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mt-4 text-sm text-red-700">
                <XCircle size={16} className="shrink-0" /> {executeError}
              </div>
            )}

            {executeResult && (
              <div className="flex items-center gap-2 bg-green-50 border border-green-200 rounded-lg px-4 py-3 mt-4 text-sm text-green-700">
                <CheckCircle size={16} className="shrink-0" /> {executeResult}
              </div>
            )}

            {/* Verify Progress */}
            {(verifyResult || verifying) && (
              <div className="mt-4">
                <div className="flex items-center gap-2 mb-2">
                  <h4 className="text-xs font-medium text-gray-600">Reassignment Progress</h4>
                  {verifying && <Loader2 size={12} className="animate-spin text-gray-400" />}
                  {verifyResult?.complete && (
                    <span className="flex items-center gap-1 text-xs text-green-600">
                      <CheckCircle size={12} /> Complete
                    </span>
                  )}
                  {verifyResult && !verifyResult.complete && (
                    <span className="flex items-center gap-1 text-xs text-blue-600">
                      <RefreshCw size={12} className="animate-spin" /> In Progress
                    </span>
                  )}
                </div>

                {verifyResult && verifyResult.partitions.length > 0 && (
                  <div className="border rounded-lg overflow-hidden">
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="bg-gray-50 border-b text-gray-500">
                          <th className="px-3 py-2 text-left font-medium">Partition</th>
                          <th className="px-3 py-2 text-left font-medium">Status</th>
                        </tr>
                      </thead>
                      <tbody>
                        {verifyResult.partitions.map((p, i) => (
                          <tr key={i} className="border-b last:border-0">
                            <td className="px-3 py-1.5 font-mono text-gray-700">{p.partition}</td>
                            <td className="px-3 py-1.5">
                              <span className={`inline-flex items-center gap-1 text-xs font-medium ${
                                p.status === 'completed' ? 'text-green-600' :
                                p.status === 'in_progress' ? 'text-blue-600' :
                                'text-gray-500'
                              }`}>
                                {p.status === 'completed' && <Check size={12} />}
                                {p.status === 'in_progress' && <RefreshCw size={12} className="animate-spin" />}
                                {p.status}
                              </span>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}

                {verifyError && (
                  <div className="flex items-center gap-2 bg-red-50 border border-red-200 rounded-lg px-4 py-3 mt-2 text-xs text-red-700">
                    <AlertTriangle size={14} className="shrink-0" /> {verifyError}
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      )}

      {/* Empty state */}
      {!distribution && !loadingDist && !distError && (
        <div className="text-center py-12 text-gray-400 text-sm">
          Loading partition distribution...
        </div>
      )}
    </div>
  );
}
