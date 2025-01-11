import { NodeProps } from 'reactflow';

export function wrapNode<T>(
  SolarSystemNode: React.FC<NodeProps<T>>
): React.FC<NodeProps<T>> {
  return function NodeAdapter(props) {
    return <SolarSystemNode {...props} />;
  };
}
