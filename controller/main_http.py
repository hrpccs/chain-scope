import datetime
import os
import json
import threading
import time
import queue
from collections import defaultdict
from threading import Lock
from flask import Flask, request, Response
import grpc
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2_grpc
from opentelemetry.proto.collector.trace.v1 import trace_service_pb2
from opentelemetry.proto.collector.logs.v1 import logs_service_pb2
from concurrent import futures

DEBUG = os.getenv("DEBUG", False) not in ['False', 'false', '0']
IDLE = os.getenv("IDLE", False) not in ['False', 'false', '0'] # we just receive data and do statistics

print(f"DEBUG={DEBUG}")
print(f"IDLE={IDLE}")

app = Flask(__name__)
class SimpleTraceHandler:
    def __init__(self):
        self.lock = threading.Lock()
        self.stats = {
            'total_spans': 0,
        }
        self.STATS_PRINT_INTERVAL = 10  # seconds
        self.running = True
        self.stats_thread = threading.Thread(target=self._stats_printer_thread)
        self.stats_thread.daemon = True
        self.stats_thread.start()

    def process_export(self, request_data):
        """Handle exported trace data"""
        try:
            # Parse the protobuf message from binary data
            trace_request = trace_service_pb2.ExportTraceServiceRequest()
            trace_request.ParseFromString(request_data)

            span_count = 0
            for resource_spans in trace_request.resource_spans:
                for scope_spans in resource_spans.scope_spans:
                    span_count += len(scope_spans.spans)
                    if DEBUG:
                        for span in scope_spans.spans:
                            print("Received span:", span)

            with self.lock:
                self.stats['total_spans'] += span_count

            # Create and return response
            response = trace_service_pb2.ExportTraceServiceResponse()
            return response.SerializeToString()
        except Exception as e:
            print(f"Error processing trace data: {e}")
            return None

    def _print_statistics(self):
        print(f"Total spans: {self.stats['total_spans']}")

    def _stats_printer_thread(self):
        while self.running:
            try:
                self._print_statistics()
                time.sleep(self.STATS_PRINT_INTERVAL)
            except Exception as e:
                print(f"Error in trace stats printer thread: {e}")
                time.sleep(1)

    def stop(self):
        self.running = False
        if self.stats_thread.is_alive():
            self.stats_thread.join()
        print("\nFinal trace statistics:")
        self._print_statistics()

class Trace:
    def __init__(self,traceid=0):
        self.lock = threading.Lock()
        self.traceid = traceid;
        self.root_spanid = None
        self.events = []
        # Store generated spans, key is spanid
        self.spans = {}
        # Store parent-child relationships of spans, key is parent spanid, value is list of child spanids
        self.span_children = {}
        # Used to generate random spanid
        self.next_span_id = 1
        # Store socket events in a hash table, key is (socketid, traceid), value is list of events
        self.socket_events = {}

        self.nodename_tgid_client_spanid = defaultdict(set)  # {nodename: set(spanid)}
        self.tcp_seq_server_spanid = defaultdict(set)  # {tcp_seq: set(spanid)}
        self.unprocessed_span_index = set()  # Set of events that have not successfully formed a span
        self.processed_span_index = set()  # Set of events that have successfully formed a span

        self.completed = False
        self.last_try_time = time.time()
        self.try_count = 0

        # Configuration parameters
        self.TRACE_BUILD_RETRY_INTERVAL = 5   # Retry interval (seconds)
        self.MAX_TRACE_BUILD_RETRIES = 3      # Maximum number of retries

    def add_event(self, event):
        with self.lock:
            self.events.append(event)

    def _update_span_index(self, spanid, span):
        """Update span index"""
        if span['type'] == 'client':
            self.nodename_tgid_client_spanid.setdefault((span['nodename'],span['tgid']), set()).add(spanid)
        elif span['type'] == 'server':
            # Index by tcp_seq
            self.tcp_seq_server_spanid.setdefault(span['tcp_seq'], set()).add(spanid)

    def have_unprocessed_events(self):
        with self.lock:
            return len(self.events) > 0
    
    def have_unprocessed_spans(self):
        with self.lock:
            return len(self.unprocessed_span_index) > 0

    def _try_create_spans(self):
        with self.lock:
            socket_map = {}
            for event in self.events:
                socketid = event['socketid']

                if socketid not in socket_map:
                    socket_map[socketid] = list()
            
                socket_map[socketid].append(event)

            for socketid, events in socket_map.items():
            
                # Check if event pairs are complete
                if len(events) < 2:
                    continue
            
                if len(events) > 2:
                    print(f"ERROR: Trace {self.traceid} more than one span in socket {socketid}")
                
                # Process event pairs
                events_sorted = sorted(events, key=lambda e: e['timestamp'])
                has_ingress = any(e['direction'] == 'ingress' for e in events_sorted)
                has_egress = any(e['direction'] == 'egress' for e in events_sorted)
            
                if not (has_ingress and has_egress):
                    continue
                
                first_event, second_event = events_sorted[0], events_sorted[1]
            
                # Determine span type
                if first_event['direction'] == 'ingress':
                    span_type = 'server'
                    start_event, end_event = first_event, second_event
                else:
                    span_type = 'client'
                    start_event, end_event = first_event, second_event
            
                # Generate spanid
                spanid = self._generate_span_id()

                # Create span object
                span = {
                    'spanid': spanid,
                    'traceid': self.traceid,
                    'type': span_type,
                    'start_time': start_event['timestamp'],
                    'end_time': end_event['timestamp'],
                    'nodename': start_event['nodename'],
                    'tgid': start_event['tgid'],
                    'tcp_seq': start_event['tcp_seq'],
                    'new_trace_flag': start_event['new_trace_flag'],
                    'parent_spanid': None,
                    'socketid': socketid
                }
            
                # Update data structures
                self.spans[spanid] = span
                self._update_span_index(spanid, span)
                self.unprocessed_span_index.add(spanid)
                # Handle new trace case
                if span['new_trace_flag']:
                    self.root_spanid = spanid

    def _try_build_span_tree(self):
        """Try to build span tree"""
        with self.lock:
            # If there are no unprocessed spans, return directly
            if len(self.unprocessed_span_index) == 0 or self.root_spanid is None:
                return
            
            # Too short since last retry, do not retry yet
            if time.time() - self.last_try_time < self.TRACE_BUILD_RETRY_INTERVAL:
                return
            
            # If already tried, return directly
            if self.try_count >= self.MAX_TRACE_BUILD_RETRIES:
                return
            
            self.last_try_time = time.time()
            self.try_count += 1

            # Try to build span tree, bfs
            queue = [self.root_spanid]
            while queue.count > 0:
                spanid = queue.pop(0)
                if spanid in self.processed_spanid:
                    # Already processed, skip
                    child_spans = self.span_children.get(spanid, [])
                    for child_spanid in child_spans:
                        queue.append(child_spanid)
                    continue

                self.processed_span_index.add(spanid)
                self.unprocessed_span_index.remove(spanid)

                # Process current span
                span = self.spans.get(spanid)
                if span['type'] == 'server':
                    # If server span, need client span on the same service
                    same_service_server_spans = self.nodename_tgid_client_spanid.get((span['nodename'], span['tgid']))
                    for candidate_span in same_service_server_spans:
                       if spanid not in self.span_children:
                            self.span_children[spanid] = []    
                       self.span_children[spanid].append(candidate_span)
                       queue.append(candidate_span)
                       self.spans[candidate_span]['parent_spanid'] = spanid
                                
                elif span['type'] == 'client':
                    # If client span, need to find server span with the same tcp_seq
                    same_tcp_seq_server_spans = self.tcp_seq_server_spanid.get(span['tcp_seq'])
                    for candidate_span in same_tcp_seq_server_spans:
                        if spanid not in self.span_children:
                            self.span_children[spanid] = []
                        self.span_children[spanid].append(candidate_span)
                        queue.append(candidate_span)
                        self.spans[candidate_span]['parent_spanid'] = spanid

    def _print_span_sub_tree(self,spanid, level=0):
        span = self.spans.get(spanid)
        if not span:
            print(f"[DEBUG] Unable to print span tree for {self.traceid}: spanid={spanid} does not exist")
            return
        indent = "  " * level
        
        # Build basic info
        span_info = [
            f"Span: {spanid}",
            f"Type: {span['type']}",
            f"Node: {span['nodename']}",
            f"Tgid: span['tgid']",
            f"Time: {span['start_time']} -> {span['end_time']}",
            f"TCP Seq: {span['tcp_seq']}"
        ]
        
        # Add parent info
        if span['parent_spanid'] is not None:
            span_info.append(f"Parent: {span['parent_spanid']}")
        elif span['new_trace_flag']:
            span_info.append("(Root Span)")
        
        # Print current node info
        print(f"{indent}[{' | '.join(span_info)}]")
        
        children = self.span_children.get(spanid, [])
        for child_spanid in children:
            for child_spanid in children:
                self._print_span_sub_tree(child_spanid, level + 1)
    
    def _print_span_tree(self):
        with self.lock:
            if self.root_spanid is not None:
                self._print_span_sub_tree(self.root_spanid,0)
    
    def _generate_span_id(self):
        """Generate unique spanid"""
        spanid = self.next_span_id
        self.next_span_id += 1
        return spanid

class SimpleLogHandler:
            
    def __init__(self):
        # Store span trees, key is traceid, value is root spanid
        self.lock = threading.Lock()
        self.trace_trees = {}
        
        self.BUILD_BATCH_INTERVAL = 0.1  # Batch build interval (seconds)
        self.TRACE_BUILD_TIMEOUT = 30         # Trace build timeout (seconds)
        self.STATS_PRINT_INTERVAL = 10        # Statistics print interval (seconds)
        self.EVENT_BATCH_SIZE = 10000           # Number of events per batch
        self.TRACE_BUILD_RETRY_INTERVAL = 5   # Retry interval (seconds)
       
        self.stats = {
            'total_events': 0,          # Total number of events
        } 
        
        # Event queue
        self.event_queue = queue.Queue(maxsize=0)
        
        # Thread control
        self.running = True
        
        # Start statistics print thread
        self.stats_thread = threading.Thread(target=self._stats_printer_thread)
        self.stats_thread.daemon = True
        self.stats_thread.start()
        
        # Start event processing thread
        self.event_processor_thread = threading.Thread(target=self._event_processor_thread)
        self.event_processor_thread.daemon = True
        self.event_processor_thread.start()
        
        # Start build queue processing thread
        self.build_processor_thread = threading.Thread(target=self._build_processor_thread)
        self.build_processor_thread.daemon = True
        self.build_processor_thread.start()
    
    def process_export(self, request_data):
        """Handle exported log data"""
        try:
            # Parse the protobuf message from binary data
            log_request = logs_service_pb2.ExportLogsServiceRequest()
            log_request.ParseFromString(request_data)
            
            # Process received log data
            for resource_logs in log_request.resource_logs:
                # Process resource information
                resource_info = self._extract_resource_info(resource_logs.resource)
                
                # Process log records
                for scope_logs in resource_logs.scope_logs:
                    scope_info = self._extract_scope_info(scope_logs.scope)
                    
                    for log_record in scope_logs.log_records:
                        self._process_log_record(log_record, resource_info, scope_info)
            
            # Return success response
            response = logs_service_pb2.ExportLogsServiceResponse()
            return response.SerializeToString()
            
        except Exception as e:
            print(f"Error processing log data: {e}")
            return None
    
    def _extract_resource_info(self, resource):
        # Extract attribute information from the resource object and return as a dictionary.
        
        # Args:
        #     resource: Resource object containing attributes
        
        # Returns:
        #     dict: Dictionary containing resource attribute key-value pairs, returns empty dict if resource is None
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
        """Process a single log record by adding it to the event queue"""
        event_data = json.loads(log_record.body.string_value)
        # Build event object
        event = {
            'event_type': event_data['event_type'],
            'new_trace_flag': bool(event_data['new_trace_flag']),
            'merged': bool(event_data['merged']),
            'traceid': int(event_data['traceid']),
            'direction': 'egress' if bool(event_data['direction']) else 'ingress',
            'socketid': int(event_data['socketid']),
            'pid': int(event_data['pid']),
            'tgid': int(event_data['tgid']),
            'timestamp': int(event_data['timestamp']),
            'tcp_seq': int(event_data['tcp_seq']),
            'ip_src': int(event_data['ip_src']),
            'ip_dst': int(event_data['ip_dst']),
            'port_src': int(event_data['port_src']),
            'port_dst': int(event_data['port_dst']),
            'protocol': int(event_data['protocol']),
            'nodename': event_data['nodename'],
            'streamids': event_data['streamids'],
            'old_traceid': event_data['old_traceid'],
            'old_streamids': event_data['old_streamids']
        }
        if DEBUG:
            print(f"Received event: {event}")
        if IDLE:
            self.stats['total_events'] += 1
        else:
            try:
                # Add event to queue
                self.event_queue.put(event, block=True)
                self.stats['total_events'] += 1
        
            except Exception as e:
                print(f"Error processing log record: {e}")
    
    def _event_processor_thread(self):
        """Background thread for processing events from the queue"""
        while self.running:
            try:
                events = []
                for _ in range(self.EVENT_BATCH_SIZE):
                    try:
                        event = self.event_queue.get_nowait()
                        events.append(event)
                    except queue.Empty:
                        break
                
                with self.lock:
                    for event in events:
                        traceid = event['traceid']
                        trace = self.trace_trees.get(traceid)
                        if trace is None:
                            # Create new trace tree
                            trace = Trace(traceid)
                            trace.add_event(event)
                            self.trace_trees[traceid] = trace
                        else:
                            trace.add_event(event)
            except Exception as e:
                print(f"Error in event processor thread: {e}")
                time.sleep(1)  # Wait for a while before continuing after error
    
    def _build_processor_thread(self):
        """Background thread, periodically processes build queue and timed out traces"""
        while self.running:
            try:
                with self.lock:
                    for traceid,trace in self.trace_trees.items():
                        if trace.have_unprocessed_events():
                            trace._try_create_spans()
                        
                        if trace.have_unprocessed_spans():
                            trace._try_build_span_tree()  
                        
                        if DEBUG:
                            trace._print_span_tree()
                
                # Sleep according to configuration interval
                time.sleep(self.TRACE_BUILD_RETRY_INTERVAL)
                
            except Exception as e:
                print(f"Error in build processor thread: {e}")
                time.sleep(1)  # Wait for a while before continuing after error

    def _print_statistics(self):
        """Print statistics"""
        print(f"Total events: {self.stats['total_events']}") 

    
    def _stats_printer_thread(self):
        """Background thread, periodically prints statistics"""
        while self.running:
            try:
                self._print_statistics()
                time.sleep(self.STATS_PRINT_INTERVAL)
            except Exception as e:
                print(f"Error in stats printer thread: {e}")
                # Wait for a while before continuing after error
                time.sleep(1)
    
    def stop(self):
        """Stop all background threads and ensure cleanup"""
        print("Stopping log handler...")
        self.running = False
        
        # Wait for event processing thread to finish
        if self.event_processor_thread.is_alive():
            print("Waiting for event processor thread to finish...")
            remaining_events = self.event_queue.qsize()
            if remaining_events > 0:
                print(f"Processing remaining {remaining_events} events...")
            self.event_processor_thread.join()
            print("Event processor thread stopped")
        
        # Wait for build processor thread to finish
        if self.build_processor_thread.is_alive():
            print("Waiting for build processor thread to finish...")
            self.build_processor_thread.join()
            print("Build processor thread stopped")
        
        # Wait for statistics print thread to finish
        if self.stats_thread.is_alive():
            print("Waiting for stats printer thread to finish...")
            self.stats_thread.join()
            print("Stats printer thread stopped")
        
        # Print final statistics
        print("\nFinal statistics:")
        self._print_statistics()

# Initialize handlers
trace_handler = SimpleTraceHandler()
log_handler = SimpleLogHandler()

@app.route('/', methods=['GET'])
def health_check():
    """Health check endpoint for Docker healthcheck"""
    return {"status": "ok", "service": "otlp-http-receiver"}, 200

@app.route('/v1/traces', methods=['POST'])
def handle_traces():
    """HTTP endpoint for receiving trace data"""
    try:
        # Get binary protobuf data from request
        request_data = request.data
        
        # Process the trace data
        response_data = trace_handler.process_export(request_data)
        
        if response_data:
            return Response(response_data, mimetype='application/x-protobuf')
        else:
            return Response(status=200)
    except Exception as e:
        print(f"Error in trace endpoint: {e}")
        return Response(status=500)

@app.route('/v1/logs', methods=['POST'])
def handle_logs():
    """HTTP endpoint for receiving log data"""
    try:
        # Get binary protobuf data from request
        request_data = request.data
        
        # Process the log data
        response_data = log_handler.process_export(request_data)
        
        if response_data:
            return Response(response_data, mimetype='application/x-protobuf')
        else:
            return Response(status=200)
    except Exception as e:
        print(f"Error in log endpoint: {e}")
        return Response(status=500)

class SimpleTraceService(trace_service_pb2_grpc.TraceServiceServicer):
    def __init__(self):
        self.lock = threading.Lock()
        self.total_spans = 0
        self.STATS_PRINT_INTERVAL = 10  # seconds
        self.running = True
        self.stats_thread = threading.Thread(target=self._stats_printer_thread)
        self.stats_thread.daemon = True
        self.stats_thread.start()

    def Export(self, request, context):
        span_count = 0
        for resource_spans in request.resource_spans:
            for scope_spans in resource_spans.scope_spans:
                span_count += len(scope_spans.spans)
                if DEBUG:
                    for span in scope_spans.spans:
                        print("Received span:", span)
        with self.lock:
            self.total_spans += span_count
        return trace_service_pb2.ExportTraceServiceResponse()

    def _print_statistics(self):
        print(f"[gRPC] Total spans: {self.total_spans}")

    def _stats_printer_thread(self):
        while self.running:
            try:
                self._print_statistics()
                time.sleep(self.STATS_PRINT_INTERVAL)
            except Exception as e:
                print(f"Error in gRPC trace stats printer thread: {e}")
                time.sleep(1)

    def stop(self):
        self.running = False
        if self.stats_thread.is_alive():
            self.stats_thread.join()
        print("\nFinal gRPC trace statistics:")
        self._print_statistics()

import concurrent.futures

def serve_grpc():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    trace_service_pb2_grpc.add_TraceServiceServicer_to_server(SimpleTraceService(), server)
    # logs_service_pb2_grpc.add_LogsServiceServicer_to_server(SimpleLogService(), server)  # Uncomment if you have SimpleLogService
    server.add_insecure_port('[::]:4317')  # Default OTLP gRPC port
    server.start()
    print("OTLP Trace Receiver running on port 4317")
    server.wait_for_termination()

def serve():
    """Start the HTTP server"""
    print("OTLP HTTP Receiver running on port 4318")  # Default OTLP HTTP port
    try:
        app.run(host='0.0.0.0', port=4318)
    except KeyboardInterrupt:
        print("Shutting down server...")
    finally:
        # Ensure statistics print thread is stopped when service shuts down
        log_handler.stop()

if __name__ == '__main__':
    t1 = threading.Thread(target=serve)
    t2 = threading.Thread(target=serve_grpc)
    t1.start()
    t2.start()
    t1.join()
    t2.join()