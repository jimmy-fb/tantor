import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { ChevronRight, ChevronLeft, Check, Server, Loader2 } from 'lucide-react';
import type { Host, KafkaVersionInfo, ClusterCreate, ServiceAssignment, ClusterConfig } from '../../types';
import { getHosts, createCluster, getKafkaVersions } from '../../lib/api';

const ROLES = [
  { id: 'broker_controller', label: 'Broker + Controller', description: 'Combined KRaft broker and controller (recommended for small clusters)', color: 'bg-blue-100 text-blue-800 border-blue-200' },
  { id: 'broker', label: 'Broker', description: 'Kafka broker only (data plane)', color: 'bg-green-100 text-green-800 border-green-200' },
  { id: 'controller', label: 'Controller', description: 'KRaft controller only (metadata)', color: 'bg-purple-100 text-purple-800 border-purple-200' },
  { id: 'ksqldb', label: 'ksqlDB', description: 'Stream processing SQL engine', color: 'bg-orange-100 text-orange-800 border-orange-200' },
  { id: 'kafka_connect', label: 'Kafka Connect', description: 'Data integration framework', color: 'bg-teal-100 text-teal-800 border-teal-200' },
  { id: 'zookeeper', label: 'ZooKeeper', description: 'Legacy consensus (use KRaft instead)', color: 'bg-gray-100 text-gray-800 border-gray-200' },
];

// Roles that are mutually exclusive per host
const EXCLUSIVE_GROUPS: Record<string, string[]> = {
  broker_controller: ['broker', 'controller'],
  broker: ['broker_controller'],
  controller: ['broker_controller'],
};

export default function ClusterWizard() {
  const navigate = useNavigate();
  const [step, setStep] = useState(0);
  const [hosts, setHosts] = useState<Host[]>([]);
  const [versions, setVersions] = useState<KafkaVersionInfo[]>([]);
  const [versionsLoading, setVersionsLoading] = useState(true);
  const [loading, setLoading] = useState(false);

  // Step 1: Cluster basics
  const [name, setName] = useState('');
  const [kafkaVersion, setKafkaVersion] = useState('');
  const [mode, setMode] = useState<'kraft' | 'zookeeper'>('kraft');

  // Step 2: Role assignment — multi-role per host
  const [assignments, setAssignments] = useState<Record<string, string[]>>({});

  // Step 3: Configuration
  const [config, setConfig] = useState<ClusterConfig>({
    replication_factor: 3,
    num_partitions: 3,
    log_dirs: '/var/lib/kafka/data',
    listener_port: 9092,
    controller_port: 9093,
    heap_size: '1G',
    ksqldb_port: 8088,
    connect_port: 8083,
    connect_rest_port: 8083,
  });

  useEffect(() => {
    getHosts().then(setHosts);
    setVersionsLoading(true);
    getKafkaVersions()
      .then(data => {
        setVersions(data);
        // Default select first available version
        const available = data.filter(v => v.available);
        if (available.length > 0 && !kafkaVersion) {
          setKafkaVersion(available[0].version);
        } else if (data.length > 0 && !kafkaVersion) {
          setKafkaVersion(data[0].version);
        }
      })
      .catch(() => setVersions([]))
      .finally(() => setVersionsLoading(false));
  }, []);

  const handleAssign = (hostId: string, role: string) => {
    setAssignments(prev => {
      const current = prev[hostId] || [];
      if (current.includes(role)) {
        // Remove the role
        const next = current.filter(r => r !== role);
        if (next.length === 0) {
          const copy = { ...prev };
          delete copy[hostId];
          return copy;
        }
        return { ...prev, [hostId]: next };
      } else {
        // Add the role, removing any exclusive roles
        const exclusions = EXCLUSIVE_GROUPS[role] || [];
        const filtered = current.filter(r => !exclusions.includes(r));
        return { ...prev, [hostId]: [...filtered, role] };
      }
    });
  };

  const buildServices = (): ServiceAssignment[] => {
    let nodeId = 1;
    const services: ServiceAssignment[] = [];
    for (const [hostId, roles] of Object.entries(assignments)) {
      for (const role of roles) {
        services.push({ host_id: hostId, role, node_id: nodeId++ });
      }
    }
    return services;
  };

  const handleCreate = async () => {
    setLoading(true);
    try {
      const data: ClusterCreate = {
        name,
        kafka_version: kafkaVersion,
        mode,
        services: buildServices(),
        config,
      };
      const cluster = await createCluster(data);
      navigate(`/clusters/${cluster.id}`);
    } finally {
      setLoading(false);
    }
  };

  const assignedRoles = Object.values(assignments).flat();
  const hasBroker = assignedRoles.some(r => r === 'broker' || r === 'broker_controller');
  const availableVersions = versions.filter(v => v.available);
  const selectedVersion = versions.find(v => v.version === kafkaVersion);

  const steps = [
    {
      title: 'Cluster Basics',
      content: (
        <div className="space-y-6">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Cluster Name</label>
            <input
              type="text"
              value={name}
              onChange={e => setName(e.target.value)}
              placeholder="my-kafka-cluster"
              className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Kafka Version</label>
            {versionsLoading ? (
              <div className="flex items-center gap-2 text-sm text-gray-400 py-2">
                <Loader2 size={14} className="animate-spin" /> Loading available versions...
              </div>
            ) : versions.length === 0 ? (
              <div className="text-sm text-red-500 py-2">
                No versions found. Upload a Kafka binary on the{' '}
                <a href="/versions" className="text-blue-600 underline">Kafka Versions</a> page.
              </div>
            ) : (
              <>
                <select
                  value={kafkaVersion}
                  onChange={e => setKafkaVersion(e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
                >
                  {availableVersions.length > 0 && (
                    <optgroup label="Available (downloaded)">
                      {availableVersions.map(v => (
                        <option key={v.version} value={v.version}>
                          {v.version} ({v.size_mb} MB)
                          {v.release_date ? ` - Released ${v.release_date}` : ''}
                        </option>
                      ))}
                    </optgroup>
                  )}
                  {versions.filter(v => !v.available).length > 0 && (
                    <optgroup label="Not Downloaded (upload required)">
                      {versions.filter(v => !v.available).map(v => (
                        <option key={v.version} value={v.version} disabled>
                          {v.version} - Not available (upload binary first)
                        </option>
                      ))}
                    </optgroup>
                  )}
                </select>
                {selectedVersion && selectedVersion.features && (
                  <div className="mt-2 text-xs text-gray-500">
                    <span className="font-medium">Features:</span>{' '}
                    {selectedVersion.features.slice(0, 3).join(', ')}
                    {selectedVersion.features.length > 3 && ` +${selectedVersion.features.length - 3} more`}
                  </div>
                )}
              </>
            )}
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-2">Consensus Mode</label>
            <div className="grid grid-cols-2 gap-3">
              <button
                onClick={() => setMode('kraft')}
                className={`p-4 border-2 rounded-xl text-left transition-colors ${
                  mode === 'kraft' ? 'border-blue-500 bg-blue-50' : 'border-gray-200 hover:border-gray-300'
                }`}
              >
                <div className="font-semibold text-sm">KRaft</div>
                <div className="text-xs text-gray-500 mt-1">Recommended. Built-in Raft consensus, no ZooKeeper needed.</div>
              </button>
              <button
                onClick={() => setMode('zookeeper')}
                className={`p-4 border-2 rounded-xl text-left transition-colors ${
                  mode === 'zookeeper' ? 'border-blue-500 bg-blue-50' : 'border-gray-200 hover:border-gray-300'
                }`}
              >
                <div className="font-semibold text-sm">ZooKeeper</div>
                <div className="text-xs text-gray-500 mt-1">Legacy mode. Requires separate ZooKeeper ensemble.</div>
              </button>
            </div>
          </div>
        </div>
      ),
      valid: name.trim().length > 0 && kafkaVersion.length > 0,
    },
    {
      title: 'Assign Roles',
      content: (
        <div>
          {hosts.length === 0 ? (
            <div className="text-center py-8 text-gray-500">
              No hosts available. <a href="/hosts" className="text-blue-600 underline">Add hosts first</a>.
            </div>
          ) : (
            <div className="space-y-4">
              <p className="text-sm text-gray-600 mb-4">
                Assign one or more roles to each host. A single host can run multiple services (e.g. Broker+Controller and ksqlDB).
              </p>
              {hosts.map(host => {
                const hostRoles = assignments[host.id] || [];
                return (
                  <div key={host.id} className="border rounded-xl p-4">
                    <div className="flex items-center gap-3 mb-3">
                      <Server size={16} className="text-gray-400" />
                      <div>
                        <span className="font-medium text-sm">{host.hostname}</span>
                        <span className="text-xs text-gray-400 ml-2">{host.ip_address}</span>
                      </div>
                      {hostRoles.length > 0 && (
                        <span className="ml-auto text-xs px-2 py-0.5 rounded-full bg-blue-50 text-blue-600 font-medium">
                          {hostRoles.length} role{hostRoles.length > 1 ? 's' : ''}
                        </span>
                      )}
                      <span className={`${hostRoles.length > 0 ? '' : 'ml-auto'} text-xs px-2 py-0.5 rounded-full ${
                        host.status === 'online' ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-500'
                      }`}>
                        {host.status}
                      </span>
                    </div>
                    <div className="flex flex-wrap gap-2">
                      {ROLES.filter(r => mode === 'kraft' ? r.id !== 'zookeeper' : r.id !== 'controller' && r.id !== 'broker_controller')
                        .map(role => (
                          <button
                            key={role.id}
                            onClick={() => handleAssign(host.id, role.id)}
                            className={`px-3 py-1.5 text-xs rounded-lg border transition-all ${
                              hostRoles.includes(role.id)
                                ? role.color + ' ring-2 ring-offset-1 ring-blue-400'
                                : 'border-gray-200 text-gray-600 hover:border-gray-400'
                            }`}
                          >
                            {role.label}
                          </button>
                        ))}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      ),
      valid: hasBroker,
    },
    {
      title: 'Configuration',
      content: (
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Replication Factor</label>
            <input
              type="number" min={1} max={10}
              value={config.replication_factor}
              onChange={e => setConfig({ ...config, replication_factor: Number(e.target.value) })}
              className="w-full px-3 py-2 border rounded-lg text-sm"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Default Partitions</label>
            <input
              type="number" min={1} max={100}
              value={config.num_partitions}
              onChange={e => setConfig({ ...config, num_partitions: Number(e.target.value) })}
              className="w-full px-3 py-2 border rounded-lg text-sm"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Broker Port</label>
            <input
              type="number"
              value={config.listener_port}
              onChange={e => setConfig({ ...config, listener_port: Number(e.target.value) })}
              className="w-full px-3 py-2 border rounded-lg text-sm"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Controller Port</label>
            <input
              type="number"
              value={config.controller_port}
              onChange={e => setConfig({ ...config, controller_port: Number(e.target.value) })}
              className="w-full px-3 py-2 border rounded-lg text-sm"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Log Directory</label>
            <input
              type="text"
              value={config.log_dirs}
              onChange={e => setConfig({ ...config, log_dirs: e.target.value })}
              className="w-full px-3 py-2 border rounded-lg text-sm font-mono"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Heap Size</label>
            <select
              value={config.heap_size}
              onChange={e => setConfig({ ...config, heap_size: e.target.value })}
              className="w-full px-3 py-2 border rounded-lg text-sm"
            >
              <option value="512M">512 MB</option>
              <option value="1G">1 GB</option>
              <option value="2G">2 GB</option>
              <option value="4G">4 GB</option>
              <option value="6G">6 GB</option>
            </select>
          </div>
          {assignedRoles.includes('ksqldb') && (
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">ksqlDB Port</label>
              <input
                type="number"
                value={config.ksqldb_port}
                onChange={e => setConfig({ ...config, ksqldb_port: Number(e.target.value) })}
                className="w-full px-3 py-2 border rounded-lg text-sm"
              />
            </div>
          )}
          {assignedRoles.includes('kafka_connect') && (
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Connect REST Port</label>
              <input
                type="number"
                value={config.connect_rest_port}
                onChange={e => setConfig({ ...config, connect_rest_port: Number(e.target.value) })}
                className="w-full px-3 py-2 border rounded-lg text-sm"
              />
            </div>
          )}
        </div>
      ),
      valid: true,
    },
    {
      title: 'Review & Create',
      content: (
        <div className="space-y-6">
          <div className="bg-gray-50 rounded-xl p-5">
            <h3 className="font-semibold text-sm text-gray-800 mb-3">Cluster Summary</h3>
            <dl className="grid grid-cols-2 gap-2 text-sm">
              <dt className="text-gray-500">Name</dt><dd className="font-medium">{name}</dd>
              <dt className="text-gray-500">Kafka Version</dt><dd className="font-medium">{kafkaVersion}</dd>
              <dt className="text-gray-500">Mode</dt><dd className="font-medium uppercase">{mode}</dd>
              <dt className="text-gray-500">Replication Factor</dt><dd className="font-medium">{config.replication_factor}</dd>
              <dt className="text-gray-500">Partitions</dt><dd className="font-medium">{config.num_partitions}</dd>
            </dl>
          </div>
          <div>
            <h3 className="font-semibold text-sm text-gray-800 mb-3">Service Assignments</h3>
            <div className="space-y-2">
              {Object.entries(assignments).map(([hostId, roles]) => {
                const host = hosts.find(h => h.id === hostId);
                return (
                  <div key={hostId} className="flex items-center gap-3 text-sm">
                    <div className="flex flex-wrap gap-1">
                      {roles.map(role => {
                        const roleInfo = ROLES.find(r => r.id === role);
                        return (
                          <span key={role} className={`px-2 py-0.5 rounded text-xs border ${roleInfo?.color}`}>
                            {roleInfo?.label}
                          </span>
                        );
                      })}
                    </div>
                    <span className="text-gray-600">{host?.hostname}</span>
                    <span className="text-gray-400">({host?.ip_address})</span>
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      ),
      valid: true,
    },
  ];

  return (
    <div>
      {/* Step indicators */}
      <div className="flex items-center gap-2 mb-8">
        {steps.map((s, i) => (
          <div key={i} className="flex items-center gap-2">
            <button
              onClick={() => i < step && setStep(i)}
              className={`flex items-center gap-2 px-3 py-1.5 rounded-full text-sm transition-colors ${
                i === step ? 'bg-blue-600 text-white' :
                i < step ? 'bg-blue-100 text-blue-700 cursor-pointer' :
                'bg-gray-100 text-gray-400'
              }`}
            >
              {i < step ? <Check size={14} /> : <span className="w-5 text-center">{i + 1}</span>}
              {s.title}
            </button>
            {i < steps.length - 1 && <ChevronRight size={16} className="text-gray-300" />}
          </div>
        ))}
      </div>

      {/* Current step content */}
      <div className="bg-white border rounded-xl p-6 mb-6">
        {steps[step].content}
      </div>

      {/* Navigation */}
      <div className="flex justify-between">
        <button
          onClick={() => setStep(s => s - 1)}
          disabled={step === 0}
          className="flex items-center gap-1 px-4 py-2 text-sm border rounded-lg hover:bg-gray-50 disabled:opacity-30"
        >
          <ChevronLeft size={16} /> Back
        </button>
        {step < steps.length - 1 ? (
          <button
            onClick={() => setStep(s => s + 1)}
            disabled={!steps[step].valid}
            className="flex items-center gap-1 px-4 py-2 text-sm bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50"
          >
            Next <ChevronRight size={16} />
          </button>
        ) : (
          <button
            onClick={handleCreate}
            disabled={loading}
            className="flex items-center gap-1 px-6 py-2 text-sm bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50"
          >
            {loading ? 'Creating...' : 'Create Cluster'}
          </button>
        )}
      </div>
    </div>
  );
}
