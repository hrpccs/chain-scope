import datetime
import os
import grpc
from concurrent import futures

from opentelemetry.proto.collector.trace.v1 import trace_service_pb2_grpc
from opentelemetry.proto.collector.logs.v1 import logs_service_pb2_grpc


DEBUG = os.getenv("DEBUG", 'False') not in ['False', 'false', '0']

ctr = 0

class SimpleTraceService(trace_service_pb2_grpc.TraceServiceServicer):
    def Export(self, request, context):
        global ctr
        ctr += 1
        for span in request.resource_spans:
            print("Received span:", span)
        if ctr % 10000 == 0:
            print(f"ctr = {ctr}")
        return trace_service_pb2.ExportTraceServiceResponse()

class SimpleLogService(logs_service_pb2_grpc.LogsServiceServicer):
    def Export(self, request, context):
        """Handle exported log data"""
        try:
            # Process received log data
            for resource_logs in request.resource_logs:
                # Process resource information
                resource_info = self._extract_resource_info(resource_logs.resource)
                
                # Process log records
                for scope_logs in resource_logs.scope_logs:
                    scope_info = self._extract_scope_info(scope_logs.scope)
                    
                    for log_record in scope_logs.log_records:
                        self._process_log_record(log_record, resource_info, scope_info)
            
            # Return success response
            return logs_service_pb2.ExportLogsServiceResponse()
            
        except Exception as e:
            self.logger.error(f"Error processing log data: {e}")
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details(f"Internal error: {str(e)}")
            return logs_service_pb2.ExportLogsServiceResponse()
    
    def _extract_resource_info(self, resource):
        """Extract resource information"""
        if not resource:
            return {}
        
        resource_info = {}
        for attribute in resource.attributes:
            key = attribute.key
            value = self._extract_attribute_value(attribute.value)
            resource_info[key] = value
        
        return resource_info
    
    def _extract_scope_info(self, scope):
        """Extract scope information"""
        if not scope:
            return {}
        
        return {
            'name': scope.name,
            'version': scope.version
        }
    
    def _extract_attribute_value(self, any_value):
        """Extract attribute value"""
        if any_value.HasField('string_value'):
            return any_value.string_value
        elif any_value.HasField('bool_value'):
            return any_value.bool_value
        elif any_value.HasField('int_value'):
            return any_value.int_value
        elif any_value.HasField('double_value'):
            return any_value.double_value
        elif any_value.HasField('array_value'):
            return [self._extract_attribute_value(v) for v in any_value.array_value.values]
        elif any_value.HasField('kvlist_value'):
            return {kv.key: self._extract_attribute_value(kv.value) 
                    for kv in any_value.kvlist_value.values}
        else:
            return str(any_value)
    
    def _process_log_record(self, log_record, resource_info, scope_info):
        """Process a single log record"""
        
        # Extract attributes
        attributes = {}
        for attribute in log_record.attributes:
            key = attribute.key
            value = self._extract_attribute_value(attribute.value)
            attributes[key] = value
        print(f"Received log: {attributes}")
        
        has_streamids = False
        if attributes.get('streamids'):
            has_streamids = True
            # TODO: handle streamids, including the traceid merging event and drop event

        #TODO: measure trace reconstruction accuracy, including the rename and drop event



def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    trace_service_pb2_grpc.add_TraceServiceServicer_to_server(SimpleTraceService(), server)
    logs_service_pb2_grpc.add_LogsServiceServicer_to_server(SimpleLogService(), server)
    
    server.add_insecure_port('[::]:4317')  # Default OTLP gRPC port
    server.start()
    print("OTLP Trace Receiver running on port 4317")
    server.wait_for_termination()


if __name__ == '__main__':
    serve()
