import ClusterWizard from '../components/clusters/ClusterWizard';

export default function NewCluster() {
  return (
    <div>
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-gray-900">Create New Cluster</h1>
        <p className="text-sm text-gray-500 mt-1">Configure and deploy a Kafka cluster to your hosts</p>
      </div>
      <ClusterWizard />
    </div>
  );
}
