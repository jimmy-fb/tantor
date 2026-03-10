import { useState, useEffect } from 'react';
import { Plus } from 'lucide-react';
import type { Host } from '../types';
import { getHosts, createHost } from '../lib/api';
import HostList from '../components/hosts/HostList';
import AddHostModal from '../components/hosts/AddHostModal';

export default function Hosts() {
  const [hosts, setHosts] = useState<Host[]>([]);
  const [showModal, setShowModal] = useState(false);

  const fetchHosts = () => {
    getHosts().then(setHosts);
  };

  useEffect(() => {
    fetchHosts();
  }, []);

  return (
    <div>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold text-gray-900">Hosts</h1>
          <p className="text-sm text-gray-500 mt-1">Manage your Linux servers for Kafka deployment</p>
        </div>
        <button
          onClick={() => setShowModal(true)}
          className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm rounded-lg hover:bg-blue-700"
        >
          <Plus size={16} /> Add Host
        </button>
      </div>

      <HostList hosts={hosts} onRefresh={fetchHosts} />

      {showModal && (
        <AddHostModal
          onSubmit={async (data) => {
            await createHost(data);
            fetchHosts();
          }}
          onClose={() => setShowModal(false)}
        />
      )}
    </div>
  );
}
