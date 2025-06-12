from typing import Optional
import re
import argparse
import yaml

parser = argparse.ArgumentParser(prog='Manage Glueops tasks')
parser.add_argument('--upgrade-addons', action="store_true")
parser.add_argument('--upgrade-ami-version', action="store_true")
parser.add_argument('--upgrade-kubernetes-version', action="store_true")
parser.add_argument('--base-path', required=True)


args = parser.parse_args()


def read_file(filepath)-> list[str]:
    lines = []
    with open(filepath, 'r') as file:
        for i, line in enumerate(file, 1):
            lines.append(line)
    return lines

def write_file(filepath:str,lines:list[str]):
    with open(filepath, "w") as f:
        for i in lines:
            f.write(i)

def copy_lines(lines:list[str],start:int,end:int,ami_version:Optional[str]):
    new_lines = []
    for line in lines[start:end]:
        if '"name" :' in line:
            index_line = line.replace('",\n','')
            index = int(index_line.split("-")[-1])
            line = line.replace(f"-{index}",f"-{index+1}")
        elif "ami_release_version" in line and ami_version:
            end_index = line.find('",')
            start_index = line.find(': "')
            line = line.replace(line[start_index+3:end_index],ami_version)
        new_lines.append(line)
    return new_lines

def add_new_node_pool(lines:list[str], start:int,end:int,ami_release_version:Optional[str]):
    print("upgrading nodepool")
    copied_lines = copy_lines(lines,start,end,ami_release_version)
    lines[end-1] = lines[end-1].replace("}","},")
    new_lines = lines[:end] + copied_lines + lines[end:]
    return new_lines
    
def update_addons_version(lines:list[str], csi_driver_version:Optional[str],coredns_version:Optional[str],kube_proxy_version:Optional[str])->list[str]:
    print("upgrading addons")
    new_lines = []
    for line in lines:
        element = None
        if 'csi_driver_version' in line and csi_driver_version:
            element = csi_driver_version
        if 'coredns_version' in line and coredns_version:
            element = coredns_version
        if 'kube_proxy_version' in line and kube_proxy_version: 
            element = kube_proxy_version
        if element:
            start_index = line.find('= "')
            end_index = line[start_index+3:].index('"')
            line = line.replace(line[start_index+3:end_index+start_index+3],element)
        new_lines.append(line)
    return new_lines


def upgrade_kubernetes_version(lines: list[str], eks_version:str):
    print("updating kubernetes version")
    new_lines = []
    for line in lines:
        element = None
        if 'eks_version' in line and eks_version :
            element = eks_version
            start_index = line.find('= "')
            end_index = line[start_index+3:].index('"')
            line = line.replace(line[start_index+3:end_index+start_index+3],element)
        new_lines.append(line)
    return new_lines


def find_value(key:str, filepath:str):
    with open(filepath, 'r') as file:
        yaml_file = yaml.safe_load(file)
    
    for item in yaml_file['versions']:
        if item['name'] == key:
            return item['version']
    return None

  
def find_eks_addons(filepath:str)-> dict[str,str]:
    versions = {}
    for key in EKS_ADDONS:
        version = find_value(key, filepath)
        if version:
            versions[key] = version
    return versions

def find_ami_version(filepath:str)-> dict[str,str]:
    with open(filepath, "r") as f:
        hcl_content = f.read()
    version = find_value("ami_release_version", hcl_content)
    if not version:
        print("ami_version not found")
        return {}
    return {"ami_release_version": version}

def find_eks_version(filepath:str):
    version = find_value("eks_version", filepath)
    if not version:
        print("eks_version not found")
        return None
    return version


EKS_ADDONS = [
    "csi_driver_version",
    "coredns_version",
    "kube_proxy_version"
]

input_filepath = f"{args.base_path}/terraform/kubernetes/main.tf"
output_filepath = f"{args.base_path}/terraform/kubernetes/main.tf"
versions_filepath = f"{args.base_path}/VERSIONS/aws.yaml"

lines = read_file(input_filepath)

start = 12
end = 0
for item in lines:
    if "peering_configs" in item:
        end = lines.index(item)-1

if args.upgrade_addons:
    versions = find_eks_addons(versions_filepath)
    lines = update_addons_version(lines,**versions)

if args.upgrade_ami_version:
    versions = find_ami_version(versions_filepath)
    lines = add_new_node_pool(lines,start,end,**versions)

if args.upgrade_kubernetes_version:
    version = find_eks_version(versions_filepath)
    print(f"we're upgrading {version} to {version}")
    lines = upgrade_kubernetes_version(lines,f"{version}")

write_file(output_filepath,lines)




