use crate::hooks::types::go_app_specific_info;
use crate::hooks::{self, HooksSkel};
use crate::{ProbeAttachInfo, ProbeType, PODS_LIST, SERVICES_LIST, KUBE_POLL_INTERVAL};
use anyhow::Result;
use containerd_client::tonic::Request;
use libbpf_rs::{MapCore, MapFlags, MapHandle};
use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use std::fs;
use tokio::time;
use containerd_client::{self, with_namespace};
use kube::{Client, api::{Api, ListParams}};
use k8s_openapi::api::core::v1::{Pod, Service};
use crossbeam::channel::Sender;

pub struct K8sInfo {
    pub pods_list: HashMap<String, HashMap<&'static str, String>>,
    pub services_list: HashMap<String, HashMap<&'static str, String>>,
    pub node_name: String,
    pub kubernetes_service_host: String,
    pub kubernetes_port_443_tcp_port: String,
    pub serving_namespaces: Vec<String>,
    pub debug: bool,
}

pub async fn kube_poll(k8s_info: Arc<tokio::sync::Mutex<K8sInfo>>,sender: Sender<ProbeAttachInfo>) {
    println!("kube_poll");

    let containerd_channel = containerd_client::connect("/run/k3s/containerd/containerd.sock")
        .await
        .unwrap();
    let mut containerd_task_client =
        containerd_client::services::v1::tasks_client::TasksClient::new(containerd_channel);

    let mut uprobe_attached_pids : std::collections::HashSet<u32> = std::collections::HashSet::new();
    let collect_interval = Duration::from_millis(*KUBE_POLL_INTERVAL);
    let context_type_map_path = "/sys/fs/bpf/fullstacktracer/context_type_map";
    let greenlet_map_path = "/sys/fs/bpf/fullstacktracer/greenlet_tstate_tls_map";
    let service_ip_map_path = "/sys/fs/bpf/fullstacktracer/service_ip_map";
    println!("context_type_map_path:{}", context_type_map_path);
    println!("greenlet_map_path:{}", greenlet_map_path);
    println!("service_ip_map_path:{}", service_ip_map_path);

    time::sleep(Duration::from_secs(1)).await;

    let service_ip_map_handler = match MapHandle::from_pinned_path(service_ip_map_path) {
        Ok(handler) => handler,
        Err(err) => {
            eprintln!("Failed to open service_ip_map: {}", err);
            return;
        }
    };

    let context_type_map_handler = match MapHandle::from_pinned_path(context_type_map_path) {
        Ok(handler) => handler,
        Err(err) => {
            eprintln!("Failed to open context_type_map: {}", err);
            return;
        }
    };

    // Read the token from kubernetes runtime mount
    println!("Started polling Kubernetes APIs");
    // 初始化kube-rs客户端
    let client = Client::try_default().await.unwrap();
    // will read KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT env
    let node_name = k8s_info.lock().await.node_name.clone();

    loop {
        let mut pods_list_: HashMap<String, HashMap<&str, String>> = HashMap::new();
        let mut services_list_: HashMap<String, HashMap<&str, String>> = HashMap::new();

        let mut k8s_info_ = k8s_info.lock().await;

        for namespace in &k8s_info_.serving_namespaces {
            // 使用kube-rs替代原生HTTP请求获取Pods
            let pods_api: Api<Pod> = Api::namespaced(client.clone(), namespace);
            let pod_lp = ListParams::default();
            
            println!("try listing pods in namespace: {}", namespace);
            let pod_list = match pods_api.list(&pod_lp).await {
                Ok(list) => list.items,
                Err(e) => {
                    eprintln!("Error listing pods: {}", e);
                    continue;
                }
            };

            for pod in pod_list {
                if let Some(status) = &pod.status {
                    if let Some(pod_ip) = status.pod_ip.as_ref() {
                        let mut pod_info = HashMap::new();
                        let metadata = pod.metadata;
                        
                        // 完全保持原有字段提取逻辑
                        pod_info.insert(
                            "namespace",
                            metadata.namespace.as_ref().unwrap().clone(),
                        );
                        pod_info.insert(
                            "name",
                            metadata.name.as_ref().unwrap().clone(),
                        );
                        let service_name = metadata.name.as_ref().unwrap().split("-").next().unwrap().to_string();
                        pod_info.insert(
                            "service",
                            service_name.clone()
                        );

                        if let Some(app_type) = metadata.labels.as_ref().unwrap().get("app-type") {
                            pod_info.insert("app-type",app_type.clone());
                        } else {
                            pod_info.insert("app-type","unknown".to_string());
                        }

                        if let Some(spec) = &pod.spec {
                            pod_info.insert("node_name", spec.node_name.as_ref().unwrap().clone());
                        }

                        for container in status.container_statuses.as_ref().unwrap_or(&vec![]) {
                            if container.name == "istio-proxy" {
                                let container_id = container.container_id.as_ref().unwrap().split('/').last().unwrap().to_string();
                                pod_info.insert("sidecar_container_id", container_id);
                                let image = container.image.clone();
                                pod_info.insert("sidecar_image", image);
                            } else {
                                let container_id = container.container_id.as_ref().unwrap().split('/').last().unwrap().to_string();
                                pod_info.insert("container_id", container_id);
                            }
                        }
                        
                        pods_list_.insert(pod_ip.clone(), pod_info);
                    }
                }
            }

            let services_api: Api<Service> = Api::namespaced(client.clone(), namespace);
            let service_lp = ListParams::default();
            
            let service_list = match services_api.list(&service_lp).await {
                Ok(list) => list.items,
                Err(e) => {
                    eprintln!("Error listing services: {}", e);
                    continue;
                }
            };

            for service in service_list {
                if let Some(spec) = service.spec {
                    if let Some(service_ip) = spec.cluster_ip.as_ref() {
                        let mut service_info = HashMap::new();
                        let metadata = service.metadata;
                        
                        // 完全保持原有字段提取逻辑
                        service_info.insert(
                            "namespace",
                            metadata.namespace.as_ref().unwrap().clone(),
                        );
                        service_info.insert(
                            "name",
                            metadata.name.as_ref().unwrap().clone(),
                        );
                        
                        services_list_.insert(service_ip.clone(), service_info);
                    }
                }
            }
        }

        // // for some ingress gateway in kube-system namespace
        // let kube_system_ns = "istio-system";
        // {
        //     let pods_api: Api<Pod> = Api::namespaced(client.clone(), kube_system_ns);
        //     let pod_lp = ListParams::default();

        //     let pod_list = match pods_api.list(&pod_lp).await {
        //         Ok(list) => list.items,
        //         Err(e) => {
        //             eprintln!("Error listing pods: {}", e);
        //             continue;
        //         }
        //     };

            
        //     for pod in pod_list {
        //         if let Some(labels) = &pod.metadata.labels {
        //             if labels.get("app.kubernetes.io/name") == Some(&"istio-ingressgateway".to_string()) 
        //                 && pod.metadata.namespace.as_ref() == Some(&"istio-system".to_string()) {
        //                 // 找到带有标签 app.kubernetes.io/name: istio-ingressgateway 的pod
        //                 if let Some(status) = &pod.status {
        //                     if let Some(pod_ip) = status.pod_ip.as_ref() {
        //                         let mut pod_info = HashMap::new();
        //                         let metadata = pod.metadata;
                                
        //                         pod_info.insert(
        //                             "namespace",
        //                             metadata.namespace.as_ref().unwrap().clone(),
        //                         );
        //                         pod_info.insert(
        //                             "name",
        //                             metadata.name.as_ref().unwrap().clone(),
        //                         );
        //                         pod_info.insert(
        //                             "service",
        //                             metadata.name.as_ref().unwrap().split("-").next().unwrap().to_string(),
        //                         );

        //                         pod_info.insert("app-type", "istio-ingressgateway".to_string());

        //                         if let Some(spec) = &pod.spec{
        //                             pod_info.insert("node_name", spec.node_name.as_ref().unwrap().clone());
        //                         }
                                
        //                         if let Some(statuses) = status.container_statuses.as_ref() {
        //                             if let Some(container_id) = statuses.get(0).and_then(|s| s.container_id.as_ref()) {
        //                                 let container_id = container_id.split('/').last().unwrap().to_string();
        //                                 pod_info.insert("container_id", container_id);
        //                             }
        //                         }
                                
        //                         pods_list_.insert(pod_ip.clone(), pod_info);
        //                     }
        //                 }
        //             }
        //         }
        //     }

        // }
        println!("\n{} pods in the monitored namespaces", pods_list_.len());
        if k8s_info_.debug {
            println!("{:?}", pods_list_);
        }

        println!(
            "\n{} services in the monitored namespaces",
            services_list_.len()
        );
        if k8s_info_.debug {
            println!("{:?}", services_list_);
        }
        // Batch update the global variables to reduce syscalls
        if pods_list_.len() > 0 {
            k8s_info_.pods_list = pods_list_.clone();
            let mut keys = Vec::new();
            let mut values = Vec::new();
            for (ip, info) in k8s_info_.pods_list.iter() {
                let addr: Ipv4Addr = ip.parse().expect("parse failed");
                let addr_u32: u32 = addr.into();
                let addr_u8: [u8; 4] = u32_to_u8_be(addr_u32);
                let addr_le_u8: [u8; 4] = addr_u32.to_le_bytes();
                let value_u32: u32 = 0;
                let value_u8: [u8; 4] = u32_to_u8_be(value_u32);
                let value_le_u8: [u8; 4] = value_u32.to_le_bytes();

                keys.push(addr_u8);
                values.push(value_u8);
                keys.push(addr_le_u8);
                values.push(value_le_u8);

                if let Some(pod_node_name) = info.get("node_name") {
                    if pod_node_name == &node_name {
                        // pod is on the same node as the agent
                        // check if the net interface is attached with the tc ebpf program
                        let container_id_string = info.get("container_id").unwrap();
                        let container_id = container_id_string.split("/").last().unwrap();
                        let request = containerd_client::services::v1::ListPidsRequest {
                            container_id: container_id.to_string(),
                        };
                        let request = with_namespace!(request, "k8s.io");
                        let pid_list = containerd_task_client.list_pids(request).await;
                        if pid_list.is_err() {
                            println!("Error while getting pid list");
                            continue;
                        }
                        let pid = pid_list.unwrap().into_inner().processes.first().unwrap().pid;
                        if !uprobe_attached_pids.contains(&pid) {
                            if let Some(app_type) = info.get("app-type") {
                                println!("{} is a {} pod", info.get("name").unwrap(), app_type);
                                if app_type == "greenlet" {
                                    let container_id_string = info.get("container_id").unwrap();
                                    let container_id = container_id_string.split("/").last().unwrap();
                                    attach_greenlet_tls_info(&mut containerd_task_client, container_id).await;
                                    attach_context_type_to_container(&mut containerd_task_client, &context_type_map_handler, container_id, hooks::types::context_type::CONTEXT_PYTHON_GREENLET).await;
                                } else if app_type == "go-grpc" {
                                    let container_id = info.get("container_id").unwrap();
                                    let container_id = container_id.split("/").last().unwrap();
                                    attach_go_grpc_info(&mut containerd_task_client, info).await;
                                    attach_context_type_to_container(&mut containerd_task_client, &context_type_map_handler, container_id, hooks::types::context_type::CONTEXT_GOROUTINE).await;
                                        let probe_type = match info.get("service").unwrap().as_str() {
                                            "frontend" => ProbeType::GoGrpcClient,
                                            "geo" => ProbeType::GoGrpcServer,
                                            "profile" => ProbeType::GoGrpcServer,
                                            "rate" => ProbeType::GoGrpcServer,
                                            "recommendation" => ProbeType::GoGrpcServer,
                                            "reservation" => ProbeType::GoGrpcServer,
                                            "search" => ProbeType::GoGrpcBoth,
                                            "user" => ProbeType::GoGrpcServer,
                                            _ => ProbeType::NoProbe,
                                        };
                                        let attach_info = ProbeAttachInfo {
                                            pid: pid as i32,
                                            probe_type
                                        };
                                        let _ = sender.send(attach_info);
                                } else if app_type == "istio-ingressgateway" {
                                    let container_id = info.get("container_id").unwrap();
                                    let container_id = container_id.split("/").last().unwrap();
                                    attach_context_type_to_container(&mut containerd_task_client, &context_type_map_handler, container_id, hooks::types::context_type::CONTEXT_ISTIO).await;
                                } else if app_type == "nginx" {
                                    let container_id = info.get("container_id").unwrap();
                                    let container_id = container_id.split("/").last().unwrap();
                                    attach_context_type_to_container(&mut containerd_task_client, &context_type_map_handler, container_id, hooks::types::context_type::CONTEXT_ISTIO).await;
                                }
                            }
                            if let Some(sidecar_container_id) = info.get("sidecar_container_id") {
                                let container_id = sidecar_container_id;
                                let container_id = container_id.split("/").last().unwrap();
                                attach_context_type_to_container(&mut containerd_task_client, &context_type_map_handler, container_id, hooks::types::context_type::CONTEXT_ISTIO).await;
                            }
                            uprobe_attached_pids.insert(pid);
                        }
                    }
                }
            }
            if !keys.is_empty() {
            // Flatten Vec<[u8; 4]> to Vec<u8>
            let flat_keys: Vec<u8> = keys.iter().flat_map(|k| k.iter()).cloned().collect();
            let flat_values: Vec<u8> = values.iter().flat_map(|v| v.iter()).cloned().collect();
            let count = keys.len();
            service_ip_map_handler
                .update_batch(&flat_keys, &flat_values, count as u32, MapFlags::ANY, MapFlags::ANY)
                .unwrap();
            }
            let mut pods_list = PODS_LIST.lock().unwrap();
            *pods_list = pods_list_;
        }
        if services_list_.len() > 0 {
            k8s_info_.services_list = services_list_.clone();
            let mut keys = Vec::new();
            let mut values = Vec::new();
            for (ip, _) in k8s_info_.services_list.iter() {
            let addr: Ipv4Addr = ip.parse().expect("parse failed");
            let addr_u32: u32 = addr.into();
            let addr_u8: [u8; 4] = u32_to_u8_be(addr_u32);
            let addr_le_u8: [u8; 4] = addr_u32.to_le_bytes();
            let value_u32: u32 = 0;
            let value_u8: [u8; 4] = u32_to_u8_be(value_u32);
            let value_le_u8: [u8; 4] = value_u32.to_le_bytes();

            keys.push(addr_u8);
            values.push(value_u8);
            keys.push(addr_le_u8);
            values.push(value_le_u8);
            }
            if !keys.is_empty() {
            let flat_keys: Vec<u8> = keys.iter().flat_map(|k| k.iter()).cloned().collect();
            let flat_values: Vec<u8> = values.iter().flat_map(|v| v.iter()).cloned().collect();
            let count = keys.len();
            service_ip_map_handler
                .update_batch(&flat_keys, &flat_values, count as u32, MapFlags::ANY, MapFlags::ANY)
                .unwrap();
            }
            let mut services_list = SERVICES_LIST.lock().unwrap();
            *services_list = services_list_;
        }
        // envoy sidecar traffic ip
        let mut keys = Vec::new();
        let mut values = Vec::new();

        let envoy_sidecar_ip: Ipv4Addr = "127.0.0.6".parse().expect("parse failed");
        let envoy_sidecar_ip_u32: u32 = envoy_sidecar_ip.into();
        let envoy_sidecar_ip_u8: [u8; 4] = u32_to_u8_be(envoy_sidecar_ip_u32);
        let envoy_sidecar_ip_le_u8: [u8; 4] = envoy_sidecar_ip_u32.to_le_bytes();
        let value_u32: u32 = 0;
        let value_u8: [u8; 4] = u32_to_u8_be(value_u32);
        let value_le_u8: [u8; 4] = value_u32.to_le_bytes();

        keys.push(envoy_sidecar_ip_u8);
        values.push(value_u8);
        keys.push(envoy_sidecar_ip_le_u8);
        values.push(value_le_u8);

        let envoy_sidecar_ip: Ipv4Addr = "127.0.0.1".parse().expect("parse failed");
        let envoy_sidecar_ip_u32: u32 = envoy_sidecar_ip.into();
        let envoy_sidecar_ip_u8: [u8; 4] = u32_to_u8_be(envoy_sidecar_ip_u32);
        let envoy_sidecar_ip_le_u8: [u8; 4] = envoy_sidecar_ip_u32.to_le_bytes();
        let active_port = 15006;
        let value_u32: u32 = active_port;
        let value_u8: [u8; 4] = u32_to_u8_be(value_u32);
        let value_le_u8: [u8; 4] = value_u32.to_le_bytes();

        keys.push(envoy_sidecar_ip_u8);
        values.push(value_u8);
        keys.push(envoy_sidecar_ip_le_u8);
        values.push(value_le_u8);

        if !keys.is_empty() {
            let flat_keys: Vec<u8> = keys.iter().flat_map(|k| k.iter()).cloned().collect();
            let flat_values: Vec<u8> = values.iter().flat_map(|v| v.iter()).cloned().collect();
            let count = keys.len();
            service_ip_map_handler
            .update_batch(&flat_keys, &flat_values, count as u32, MapFlags::ANY, MapFlags::ANY)
            .unwrap();
        }

        tokio::time::sleep(collect_interval).await;
    }
}


async fn get_net_namespace_inode(pid: i32) -> Result<u64, Box<dyn std::error::Error>> {
    let path = PathBuf::from(format!("/proc/{}/ns/net", pid));
    // let symlink = fs::read_link(&path)?;
    let symlink = tokio::fs::read_link(&path).await?;
    let symlink_str = symlink.to_str().ok_or("Invalid symlink path")?;
    
    // 解析 `net:[12345]` 提取 inode
    let inode_str = symlink_str
        .strip_prefix("net:[")
        .and_then(|s| s.strip_suffix(']'))
        .ok_or("Invalid net namespace format")?;
    
    inode_str.parse::<u64>().map_err(|e| e.into())
}

async fn attach_go_grpc_info(containerd_task_client: &mut containerd_client::services::v1::tasks_client::TasksClient<containerd_client::tonic::transport::Channel>,pod_info: &HashMap<&str, String>) {
    let container_id = pod_info.get("container_id").unwrap();
    let container_id = container_id.split("/").last().unwrap();
    let service_name = pod_info.get("service").unwrap(); // frontend-57f9446896-frfqh
    let go_map_path = "/sys/fs/bpf/fullstacktracer/pid_go_info_map";
    let go_map_handler = match MapHandle::from_pinned_path(go_map_path) {
        Ok(handler) => handler,
        Err(err) => {
            eprintln!("Failed to open pid_go_info_map: {}", err);
            return;
        }
    };
    let request = containerd_client::services::v1::ListPidsRequest {
        container_id: container_id.to_string(),
    };
    let request = with_namespace!(request, "k8s.io");
    let pid_list = containerd_task_client.list_pids(request).await;
    if pid_list.is_err() {
        println!("Error while getting pid list");
        return;
    }

    let pid_list = pid_list.unwrap().into_inner();
    let num_of_pids = pid_list.processes.len();
    if num_of_pids != 1 {
        println!("Error while getting pid list, num_of_pids: {}", num_of_pids);
        return;
    }

    let mut service_go_info_map: HashMap<&str,go_app_specific_info> = HashMap::new();
    // datatrame: grep -nr "go:itab.*google.golang.org/grpc/internal/transport.headerFrame"
    // task: google.golang.org/grpc.(*Server).serveStreams.func1.1
    // // grpc notracing-with-symbol-2t-v1
    // service_go_info_map.insert("frontend", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xc08ee0,
    //     grpc_task_ptr: 0x90d4e0,
    // });
    // service_go_info_map.insert("geo", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe20e40,
    //     grpc_task_ptr: 0xa85b60,
    // });
    // service_go_info_map.insert("profile", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe25760,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("rate", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe24e00,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("reservation", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe27860,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("search", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xba2b00,
    //     grpc_task_ptr: 0x8dd840,
    // });
    // service_go_info_map.insert("user", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe17ac0,
    //     grpc_task_ptr: 0xa85040,
    // });
    // service_go_info_map.insert("recommendation", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe1ad40,
    //     grpc_task_ptr: 0xa85b60,
    // });

    // grpc notracing-with-symbol-2t-v1
    // service_go_info_map.insert("frontend", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xc0ae00,
    //     grpc_task_ptr: 0x90d4e0,
    // });
    // service_go_info_map.insert("geo", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe23140,
    //     grpc_task_ptr: 0xa85b60,
    // });
    // service_go_info_map.insert("profile", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe27a60,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("rate", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe270e0,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("reservation", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe2ab40,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("search", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xba5b80,
    //     grpc_task_ptr: 0x8dd840,
    // });
    // service_go_info_map.insert("user", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe19de0,
    //     grpc_task_ptr: 0xa85040,
    // });
    // service_go_info_map.insert("recommendation", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe1d060,
    //     grpc_task_ptr: 0xa85b60,
    // });

    // grpc 1.56.3 notracing-with-symbol
    service_go_info_map.insert("frontend", go_app_specific_info {
        grpc_dataframe_ptr: 0xc07e20,
        grpc_task_ptr: 0x90d4e0,
    });
    service_go_info_map.insert("geo", go_app_specific_info {
        grpc_dataframe_ptr: 0xe20ea0,
        grpc_task_ptr: 0xa85b60,
    });
    service_go_info_map.insert("profile", go_app_specific_info {
        grpc_dataframe_ptr: 0xe25780,
        grpc_task_ptr: 0xa8c300,
    });
    service_go_info_map.insert("rate", go_app_specific_info {
        grpc_dataframe_ptr: 0xe24e20,
        grpc_task_ptr: 0xa8c300,
    });
    service_go_info_map.insert("reservation", go_app_specific_info {
        grpc_dataframe_ptr: 0xe27880,
        grpc_task_ptr: 0xa8c300,
    });
    service_go_info_map.insert("search", go_app_specific_info {
        grpc_dataframe_ptr: 0xba2a40,
        grpc_task_ptr: 0x8dd840,
    });
    service_go_info_map.insert("user", go_app_specific_info {
        grpc_dataframe_ptr: 0xe17ae0,
        grpc_task_ptr: 0xa85040,
    });
    service_go_info_map.insert("recommendation", go_app_specific_info {
        grpc_dataframe_ptr: 0xe1ad60,
        grpc_task_ptr: 0xa85b60,
    });

    // // grpc 1.60.0
    // service_go_info_map.insert("frontend", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xc0ae00,
    //     grpc_task_ptr: 0x90d4e0,
    // });
    // service_go_info_map.insert("geo", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe23140,
    //     grpc_task_ptr: 0xa85b60,
    // });
    // service_go_info_map.insert("profile", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe27a60,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("rate", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe270e0,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("reservation", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe2ab40,
    //     grpc_task_ptr: 0xa8c300,
    // });
    // service_go_info_map.insert("search", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xba5b80,
    //     grpc_task_ptr: 0x8dd840,
    // });
    // service_go_info_map.insert("user", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe17ae0,
    //     grpc_task_ptr: 0xa85040,
    // });
    // service_go_info_map.insert("recommendation", go_app_specific_info {
    //     grpc_dataframe_ptr: 0xe1ad60,
    //     grpc_task_ptr: 0xa85b60,
    // });

    let key = pid_list.processes.first().unwrap().pid.to_ne_bytes();
    let go_info = service_go_info_map.get(service_name.as_str()).unwrap();
    // convert go_info to native endian bytes use plain
    let value = unsafe {
        plain::as_bytes(go_info)
    };
    let res = go_map_handler.update(&key, value, MapFlags::ANY);
    println!("attach_go_grpc_info: {:?} to service {}", go_info,service_name);
    if res.is_err() {
        println!("Failed to update go_map_handler,err {}", res.err().unwrap());
    }
}
async fn get_greenlet_pid_tls_info(pid: u32,tid_tls_map: &mut HashMap<u32, u64>) {
    println!("get_greenlet_pid_tls_info pid:{}", pid);
    let bpftrace_script = format!(
    r#"uprobe:/proc/{pid}/root/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2:__tls_get_addr
    {{
        @tid_info[tid] = arg0;
    }}
    uretprobe:/proc/{pid}/root/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2:__tls_get_addr
    {{
        @tid_greenlet_tls[tid,@tid_info[tid]] = retval;
    }}
    "#, pid=pid);
    println!("bpftrace script:");
    println!("{}", bpftrace_script);
    let script_path = format!("/tmp/greenlet_trace_{}.bt", pid);
    std::fs::write(&script_path, bpftrace_script).unwrap();
    let output_path = format!("/tmp/greenlet_trace_{}.out", pid);
    let mut child = std::process::Command::new("bpftrace")
        .arg(&script_path)
        .arg("-o")
        .arg(&output_path)
        .spawn()
        .expect("Failed to start bpftrace");
   tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
   let _ = unsafe { libc::kill(child.id() as i32, libc::SIGINT) };
   tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
   let _ = child.wait();
   let output = std::fs::read_to_string(&output_path).unwrap();
   let maps = std::fs::read_to_string(format!("/proc/{}/maps", pid)).unwrap();
   println!("output {}",output);
    let greenlet_ranges: Vec<(u64, u64)> = maps
        .lines()
        .filter(|line| line.contains("greenlet.cpython"))
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let range = parts.next()?;
            let mut range_parts = range.split('-');
            let start = u64::from_str_radix(range_parts.next()?, 16).ok()?;
            let end = u64::from_str_radix(range_parts.next()?, 16).ok()?;
            Some((start, end))
        })
        .collect();

        let min_addr = greenlet_ranges.iter().map(|(start, _)| *start).min().unwrap_or(0);
        let max_addr = greenlet_ranges.iter().map(|(_, end)| *end).max().unwrap_or(0);
        println!("min_addr {} max_addr {}",min_addr,max_addr);
        use regex::Regex;
        let re = Regex::new(r"@tid_greenlet_tls\[(\d+), (\d+)\]: (\d+)").unwrap();
        // let mut tid_tls_map = std::collections::HashMap::new();
        for cap in re.captures_iter(&output) {
            let tid: u32 = cap[1].parse().unwrap();
            let req_addr: u64 = cap[2].parse().unwrap();
            let tls_addr: u64 = cap[3].parse().unwrap();
            // 判断 req_addr 是否在 greenlet so 段, min_addr <= req_addr <= max_addr
            let in_greenlet = req_addr >= min_addr && req_addr <= max_addr;
            if in_greenlet {
                tid_tls_map.insert(tid, tls_addr);
            }
        }
        println!("Greenlet TLS info for pid {}: {:?}", pid, tid_tls_map);

}
    // get the tls info by bpftrace and binary
async fn attach_greenlet_tls_info(containerd_task_client: &mut containerd_client::services::v1::tasks_client::TasksClient<containerd_client::tonic::transport::Channel>,container_id: &str) {
    let request = containerd_client::services::v1::ListPidsRequest {
        container_id: container_id.to_string(),
    };
    let request = with_namespace!(request, "k8s.io");
    let pid_list = containerd_task_client.list_pids(request).await;
    if pid_list.is_err() {
        println!("Error while getting pid list");
        return;
    }

    let pid_list = pid_list.unwrap().into_inner();
    let pid = pid_list.processes.first().unwrap().pid;

    let greenlet_map_path = "/sys/fs/bpf/fullstacktracer/greenlet_tstate_tls_map";
    let greenlet_map_handler = match MapHandle::from_pinned_path(greenlet_map_path) {
        Ok(handler) => handler,
        Err(err) => {
            eprintln!("Failed to open greenlet_tstate_tls_map: {}", err);
            return;
        }
    };
    let mut tid_tls_map = std::collections::HashMap::new();
    get_greenlet_pid_tls_info(pid, &mut tid_tls_map).await;
    let mut keys = Vec::new();
    let mut values = Vec::new();
    let mut count=0;
    for (tid, tls) in tid_tls_map.iter() {
        let tid_u32: u32 = *tid;
        let tls_u64: u64 = *tls;
        let tid_u8: [u8; 4] = tid_u32.to_ne_bytes();
        let tls_u8: [u8; 8] = tls_u64.to_ne_bytes();
        keys.push(tid_u8);
        values.push(tls_u8);
        count+=1;
    }

    if !keys.is_empty() {
        // Flatten Vec<[u8; 4]> to Vec<u8>
        let flat_keys: Vec<u8> = keys.iter().flat_map(|k| k.iter()).cloned().collect();
        let flat_values: Vec<u8> = values.iter().flat_map(|v| v.iter()).cloned().collect();
        let count = keys.len();
        greenlet_map_handler
            .update_batch(&flat_keys, &flat_values, count as u32, MapFlags::ANY, MapFlags::ANY)
            .unwrap();
    }
    println!("greenlet tid_tls_map count:{}",count);
}

async fn attach_context_type_to_container(containerd_task_client: &mut containerd_client::services::v1::tasks_client::TasksClient<containerd_client::tonic::transport::Channel>, context_type_map_handler: &MapHandle, container_id: &str,   context_type: hooks::types::context_type) {
    let request = containerd_client::services::v1::ListPidsRequest {
        container_id: container_id.to_string(),
    };
    let request = with_namespace!(request, "k8s.io");
    let pid_list = containerd_task_client.list_pids(request).await;
    if let Ok(pid_list) = pid_list {
        let context_type_u32 = context_type.0;
        let pids = pid_list.into_inner();
        println!("container id {} pids: {:?}", container_id,pids);
        for processinfo in pids.processes {
            let pid = processinfo.pid;
            context_type_map_handler
                .update(&pid.to_ne_bytes(), &context_type_u32.to_ne_bytes(), MapFlags::ANY)
                .unwrap();
        }
    }
}

fn u32_to_u8_be(v: u32) -> [u8; 4] {
    unsafe {
        let u32_ptr: *const u32 = &v as *const u32;
        let u8_ptr: *const u8 = u32_ptr as *const u8;
        return [
            *u8_ptr.offset(3),
            *u8_ptr.offset(2),
            *u8_ptr.offset(1),
            *u8_ptr.offset(0),
        ];
    }
}

macro_rules! pin_map {
    ($map:expr, $path:expr) => {
        if !$map.is_pinned() {
            $map.pin($path).unwrap();
        }
    };
}

macro_rules! unpin_map {
    ($map:expr, $path:expr) => {
        if $map.is_pinned() {
            $map.unpin($path).unwrap();
        }
    };
}

pub fn init_maps(loaded_skel: &mut HooksSkel) {
    let path_base = "/sys/fs/bpf/fullstacktracer";

    // rm -rf /sys/fs/bpf/fullstacktracer
    if Path::new(path_base).exists() {
        fs::remove_dir_all(path_base).unwrap();
    }

    let maps = &mut loaded_skel.maps;
    {
        let map = &mut maps.sample_interval_map;
        let path = format!("{}/sample_interval_map", path_base);
        pin_map!(map, path);
    }
    {
        let map = &mut maps.service_ip_map;
        let path = format!("{}/service_ip_map", path_base);
        pin_map!(map, path);
    }
    {
        let map = &mut maps.context_type_map;
        let path = format!("{}/context_type_map", path_base);
        pin_map!(map, path);
    }
    {
        let map = &mut maps.greenlet_tstate_tls_map;
        let path = format!("{}/greenlet_tstate_tls_map", path_base);
        pin_map!(map, path);
    }
    {
        let map = &mut maps.pid_go_info_map;
        let path = format!("{}/pid_go_info_map", path_base);
        pin_map!(map, path);
    }
    // 只对 sample_interval_map 进行初始化，所有节点一样的
    {
        let key = [0u8; 4];
        let value = 1u32.to_le_bytes();
        let flags = MapFlags::ANY;
        maps.sample_interval_map.update(&key, &value, flags).unwrap();
    }
}

pub fn deinit_maps(loaded_skel: &mut HooksSkel) {
    let path_base = "/sys/fs/bpf/fullstacktracer";
    let maps = &mut loaded_skel.maps;
    {
        let map = &mut maps.sample_interval_map;
        let path = format!("{}/sample_interval_map", path_base);
        unpin_map!(map, path);
    }
    {
        let map = &mut maps.service_ip_map;
        let path = format!("{}/service_ip_map", path_base);
        unpin_map!(map, path);
    }
    {
        let map = &mut maps.context_type_map;
        let path = format!("{}/context_type_map", path_base);
        unpin_map!(map, path);
    }
    {
        let map = &mut maps.greenlet_tstate_tls_map;
        let path = format!("{}/greenlet_tstate_tls_map", path_base);
        unpin_map!(map, path);
    }
    {
        let map = &mut maps.pid_go_info_map;
        let path = format!("{}/pid_go_info_map", path_base);
        unpin_map!(map, path);
    }
}
