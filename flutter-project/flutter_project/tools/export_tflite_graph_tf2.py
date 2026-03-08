from absl import app
from absl import flags

import tensorflow.compat.v2 as tf
from google.protobuf import text_format
from object_detection import export_tflite_graph_lib_tf2
from object_detection.protos import pipeline_pb2

tf.enable_v2_behavior()

FLAGS = flags.FLAGS

flags.DEFINE_string(
    'pipeline_config_path', None,
    'Path to a pipeline_pb2.TrainEvalPipelineConfig config '
    'file.')
flags.DEFINE_string('trained_checkpoint_dir', None,
                    'Path to trained checkpoint directory')
flags.DEFINE_string('output_directory', None, 'Path to write outputs.')
flags.DEFINE_string(
    'config_override', '', 'pipeline_pb2.TrainEvalPipelineConfig '
    'text proto to override pipeline_config_path.')
flags.DEFINE_integer('max_detections', 10,
                     'Maximum number of detections (boxes) to return.')
# SSD-specific flags
flags.DEFINE_bool(
    'ssd_use_regular_nms', False,
    'Flag to set postprocessing op to use Regular NMS instead of Fast NMS '
    '(Default false).')
# CenterNet-specific flags
flags.DEFINE_bool(
    'centernet_include_keypoints', False,
    'Whether to export the predicted keypoint tensors. Only CenterNet model'
    ' supports this flag.'
)
flags.DEFINE_string(
    'keypoint_label_map_path', None,
    'Path of the label map used by CenterNet keypoint estimation task. If'
    ' provided, the label map path in the pipeline config will be replaced by'
    ' this one. Note that it is only used when exporting CenterNet model for'
    ' keypoint estimation task.'
)


def main(argv):
  del argv  # Unused.
  flags.mark_flag_as_required('pipeline_config_path')
  flags.mark_flag_as_required('trained_checkpoint_dir')
  flags.mark_flag_as_required('output_directory')

  pipeline_config = pipeline_pb2.TrainEvalPipelineConfig()

  with tf.io.gfile.GFile(FLAGS.pipeline_config_path, 'r') as f:
    text_format.Parse(f.read(), pipeline_config)
  override_config = pipeline_pb2.TrainEvalPipelineConfig()
  text_format.Parse(FLAGS.config_override, override_config)
  pipeline_config.MergeFrom(override_config)

  export_tflite_graph_lib_tf2.export_tflite_model(
      pipeline_config, FLAGS.trained_checkpoint_dir, FLAGS.output_directory,
      FLAGS.max_detections, FLAGS.ssd_use_regular_nms,
      FLAGS.centernet_include_keypoints, FLAGS.keypoint_label_map_path)


if __name__ == '__main__':
  app.run(main)