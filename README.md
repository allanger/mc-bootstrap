# New bootstrap

> Before you start reading it. All you will find here is my opinion, so treat it as that please.
> It's a list of improvements that are supposed making out life easier (not only honeybadger, but other's as well)
>
> Also, I've screwed up a bit, and I'm keep repeating `$CLUSTER-management-cluster`, where it should be something like `giantswarm-management-clusters/management-clusters/$CLUSTER`, so please read it this way

## Some kind of introduction

We have a very complicated setup, and as I see it's complicated without any real justifications for it. (Correct me if I'm wrong)
I'm only talking management cluster now. And the questions is why it has to be complicated? I can't find an answer. After all it's just a k8s cluster with some apps running in it.
A complexity of those apps doesn't matter for us, because k8s doesn't know how complex apps are.

What are problems atm?

My main problem is flux. We are going through the process of upgrading clusters to 1.25, and we need to make flux compatible with that version,  without loosing 1.24 compatibility.
It must not be an issues of any kind, as well as upgrading clusters from out perspective must no be an issues of any kind.

To us, honeybadger, the only thing that is changing with this upgrade is PSP are getting removed. And how big is that? Currently it's huge, though it should not even be really noticed.
But yet it is a problem, and since **Flux** is supposed to manage the whole cluster, it's becoming everybody's problem. And I'm going through all the steps that in my opinion are required to eliminate this problem for us and for everybody. And despite the whole change looks very big, it's not that hard to get to the point where it's all configured. Migration is not that painful, as it might seam

## Steps that should be taken in the first place

- The **Flux-app** must be refactored to support checks against K8S API
- The **Flux-app** must be reinstalled using `HelmReleases` so it's using those features


### Chart refactoring

There is a PR: https://github.com/giantswarm/flux-app/pull/241

Not all the changes are realated to the current problem, some of them are just for a sake of refactoring.
1. **PSP and related RBAC** now live in a separate tempalte, because they are not shipped with the official `install.yaml` anymore
2. **PSP and related RBAC** are now wrapped by a K8S version check:
    ```mustache
    {{- if le (atoi (.Capabilities.KubeVersion.Minor | replace "+" "")) 24 }}
    {{- end }}
    ```
    **Why do we need it?** Currenlty the default way of handling PSPs is an additional value property that is set as an override in the `config` repo.
    > In my opinion the only thing that is achieved by that approach is an additional work that has to be done by ones trying to upgrade clusters,
    > but it's my word against everybody's, so let's assume it's a right way.

    But no matter which value is set in the `config` repo, there is no point in installing `PSPs` to `1.25` because they do not exist there. So if we really need that value to be there, we can have it set like that:
    ```mustache
    {{- if le (atoi (.Capabilities.KubeVersion.Minor | replace "+" "")) 24 }}
    {{- if .Values.global.podSecurityStandards.enforced}}
    {{- end }}
    {{- end }}
    ```
3. **All the CRs** are wrapped by corresponding API checks
    ```mustache
    {{- if .Capabilities.APIVersions.Has "autoscaling.k8s.io/v1/VerticalPodAutoscaler" }}
    {{- end }}
    ```
    Because flux is supposed to manage cluster and all (or almost all) the resources in the cluster, we need to have it deploed to a cluster a soon as possible. Flux itself doesn't depend on any of those `CRs`. It's something that is added by us.

Let's talk about the last one a bit more, because, I believe, first two are covered enough.

> Security team might step in here and say that we can't have security stuff not installed in the first place. I do not agreem, but I don't think I'm really goot at it, or at least I'm not good enough to proove mmy point.
> What I can say is that:
> 1. If we don't have Kyverno installed before Flux, we have about 5 minutes where clusters can be considered vulnerable, during these 5 minutes Kyverno is getting installed and after it's there, our clusters are secured.
> 2. Flux already has policies to ignore Kyverno, so it doesn't care about security that much, Kyverno won't change anything here.
> 3. While there is only one app in the cluster and this app is Flux, there is not much to secure.
> 4. Flux-app is not a third-party helm chart, it's managed by us, so we can check security related stuff during the CI. For example, during the CI, install Kyverno to a temporary cluster, and then install Flux. If there are security related problem, Kyverno won't let flux be installed, and then CI won't pass. This way we can make sure that flux is secure enough to be running without Kyverno for ~5 minutes.

So, again. Currently we have some dependencies in the `flux-app`, that are not "real" dependencies, for instance:
- VPA CRDs
- Kyverno CRDs
- Cilium (*I'm not sure about that one, maybe it's a part of the system stuff, I just don't know*)

Because of that we need to install `VPA`, `Kyverno`, and `Cilium` before flux, or at least make `CRDs` available. But at the same time we want these apps to be managed by `Flux`.

I might be mistaken here, but as I see, their installation is described in two places
- mc-bootstrap
- default apps catalog

Talking bootstrapping, we have it defined like that:

```sh
./scripts/install-kyverno.sh
./scripts/install-vpa.sh
./scripts/install-cilium.sh
./scripts/setup-cmc.sh # <- here goes flux
```

Instead of having it we can wipe them out of the `mc-bootstrap` and make it look like that:

```sh
./scripts/setup-cmc.sh
```

If we start installing `flux` as a `HelmRelease`, the installation might look like that:

```console
# -- Let's make sure we don't have VPA CRDs first
$ k get crds
NAME                                             CREATED AT
alerts.notification.toolkit.fluxcd.io            2024-01-23T15:45:58Z
buckets.source.toolkit.fluxcd.io                 2024-01-23T15:45:58Z
gitrepositories.source.toolkit.fluxcd.io         2024-01-23T15:45:58Z
helmcharts.source.toolkit.fluxcd.io              2024-01-23T15:45:58Z
helmreleases.helm.toolkit.fluxcd.io              2024-01-23T15:45:58Z
helmrepositories.source.toolkit.fluxcd.io        2024-01-23T15:45:58Z
imagepolicies.image.toolkit.fluxcd.io            2024-01-23T15:45:58Z
imagerepositories.image.toolkit.fluxcd.io        2024-01-23T15:45:58Z
imageupdateautomations.image.toolkit.fluxcd.io   2024-01-23T15:45:58Z
kustomizations.kustomize.toolkit.fluxcd.io       2024-01-23T15:45:58Z
ocirepositories.source.toolkit.fluxcd.io         2024-01-23T15:45:58Z
providers.notification.toolkit.fluxcd.io         2024-01-23T15:45:58Z
receivers.notification.toolkit.fluxcd.io         2024-01-23T15:45:59Z

# -- Now let's install the version that has the API checks
$ helm repo add gs-catalog https://giantswarm.github.io/giantswarm-test-catalog
$ helm repo udpate
$ helm install -n flux-system flux-giantswarm gs-catalog/flux-app \
    --version  1.2.0-faa5f89120c052b3d5850504a5ed86ab93b89b55

$ kubectl get pods
NAME                                           READY   STATUS    RESTARTS   AGE
helm-controller-7bbb48888b-69rlw               1/1     Running   0          2m47s
image-automation-controller-577f789b86-pb9lk   1/1     Running   0          2m47s
image-reflector-controller-5db86f7dd4-m9jr9    1/1     Running   0          2m47s
kustomize-controller-6565d8d784-9v92f          1/1     Running   0          2m47s
notification-controller-8b9df8c7f-8m4pv        1/1     Running   0          2m47s
source-controller-65d9588f9c-h5v9p             1/1     Running   0          2m47s

# Now let's install VPA using `HelmRelease`
# You can find manifests in `./examples/vpa`
$ kubectl apply -f ./examples/vpa/

$ kubectl get helmreleases
NAME   AGE   READY   STATUS
vpa    38s   True    Release reconciliation succeeded

$ kubectl get crds
NAME                                                  CREATED AT
alerts.notification.toolkit.fluxcd.io                 2024-01-23T15:45:58Z
buckets.source.toolkit.fluxcd.io                      2024-01-23T15:45:58Z
gitrepositories.source.toolkit.fluxcd.io              2024-01-23T15:45:58Z
helmcharts.source.toolkit.fluxcd.io                   2024-01-23T15:45:58Z
helmreleases.helm.toolkit.fluxcd.io                   2024-01-23T15:45:58Z
helmrepositories.source.toolkit.fluxcd.io             2024-01-23T15:45:58Z
imagepolicies.image.toolkit.fluxcd.io                 2024-01-23T15:45:58Z
imagerepositories.image.toolkit.fluxcd.io             2024-01-23T15:45:58Z
imageupdateautomations.image.toolkit.fluxcd.io        2024-01-23T15:45:58Z
kustomizations.kustomize.toolkit.fluxcd.io            2024-01-23T15:45:58Z
ocirepositories.source.toolkit.fluxcd.io              2024-01-23T15:45:58Z
providers.notification.toolkit.fluxcd.io              2024-01-23T15:45:58Z
receivers.notification.toolkit.fluxcd.io              2024-01-23T15:45:59Z
verticalpodautoscalercheckpoints.autoscaling.k8s.io   2024-01-23T15:52:03Z
verticalpodautoscalers.autoscaling.k8s.io             2024-01-23T15:52:03Z

# Now let's check what should happen to flux once we upgrade it
$ helm diff -n flux-system flux-giantswarm gs-catalog/flux-app \
    --version  1.2.0-faa5f89120c052b3d5850504a5ed86ab93b89b55
# The full diff is in `./examples/flux-diff`
# But as an example I'll put a part of it here:
flux-system, source-controller, VerticalPodAutoscaler (autoscaling.k8s.io) has been added:
-
+ # Source: flux-app/templates/extras/vpa.yaml
+ apiVersion: autoscaling.k8s.io/v1
+ kind: VerticalPodAutoscaler
+ metadata:
+   name: source-controller
+   namespace: flux-system
+   labels:
+     app.kubernetes.io/name: "flux-app"
+     app.kubernetes.io/instance: "flux-giantswarm"
+     app.kubernetes.io/managed-by: "Helm"
+     application.giantswarm.io/team: "team-honeybadger"
+     helm.sh/chart: "flux-app-1.2.0-faa5f89120c052b3d5850504a5ed86ab93b89b55"
+     giantswarm.io/service_type: managed
+ spec:
+   resourcePolicy:
+     containerPolicies:
+     - containerName: manager
+       controlledValues: RequestsAndLimits
+       minAllowed:
+         cpu: 50m
+         memory: 64Mi
+       maxAllowed:
+         cpu: 500m
+         memory: 256Mi
+       mode: Auto
+   targetRef:
+     apiVersion: apps/v1
+     kind: Deployment
+     name: source-controller
+   updatePolicy:
+     updateMode: Auto
```

So you see, that helm is taking care of adding VPAs once they are available in the cluster. But we don't want to manage flux by hands, do we?

We will need to feed it to itself, so `flux-app` is managing itself. First, let's start with a manual approach.

In 'examples/flux' you'll find a `kustomization` that is supposed to make flux watch itself, so now let's try it out. *I assume we haven't applied that `helm-diff` change so we don't have `vpa` installed yet.

```console
$ kubectl get vpa -A
No resources found

$ kustomize build ./examples/flux | kubectl apply -f -
configmap/flux-system-flux-giantswarm-values.flux-aws.yaml created
configmap/flux-system-flux-giantswarm-values.flux.yaml created
helmrelease.helm.toolkit.fluxcd.io/flux-giantswarm created
helmrepository.source.toolkit.fluxcd.io/flux-app create

$ kubectl get vpa
NAME                          MODE   CPU    MEM         PROVIDED   AGE
helm-controller               Auto   100m   104857600   True       15s
image-automation-controller   Auto   100m   104857600   True       15s
image-reflector-controller    Auto   100m   104857600   True       15s
kustomize-controller          Auto   100m   104857600   True       15s
notification-controller       Auto   100m   104857600   True       15s
source-controller             Auto   50m    104857600   True       15s
```

So since now `flux` is managing itself, it will install `VPAs` once they are available in the cluster.

> To get there I had to set the `.spec.upgrade.force` of the `HelmRelease` to true, but I guess that in the newer flux version one can achieve it with `spec.driftDetection`

So the same should apply to `Kyverno` and `Cilium`, we don't need their `CRDs` in the cluster before flux is installed, because flux will install `CRs` once all the `CRDs` are available. 

---

Having there CRDs check is a nice to have, but not essential yet, because we're talking Kubernetes upgrade now, so let's cover it a bit more. 

Once we have Kubernetes version check in the chart and `flux-app` installed as a `HelmRelease` the upgrade path will be a way easier.
Currently, we have `cluster-management-bases` + `$CLUSTER-management-cluster`. In `$C-mc` we're getting `kustmoization` from `cmb/bases/providers/*` and those kustomization are pointing to other `kustomizations`.

Now let's have a look at what our `kustomizations` are doing, and why

---

- It's already handled by values, we can set it via them. So I don't know why we do have it here.
    ```
    images:
      - name: docker.io/giantswarm/fluxcd-helm-controller
        newName: giantswarm/fluxcd-helm-controller
      - name: docker.io/giantswarm/fluxcd-image-automation-controller
        newName: giantswarm/fluxcd-image-automation-controller
      - name: docker.io/giantswarm/fluxcd-image-reflector-controller
        newName: giantswarm/fluxcd-image-reflector-controller
      - name: docker.io/giantswarm/fluxcd-notification-controller
        newName: giantswarm/fluxcd-notification-controller
      - name: docker.io/giantswarm/fluxcd-source-controller
        newName: giantswarm/fluxcd-source-controller
      - name: docker.io/giantswarm/fluxcd-kustomize-controller
        newName: giantswarm/kustomize-controller
      - name: docker.io/giantswarm/k8s-jwt-to-vault-token
        newName: giantswarm/k8s-jwt-to-vault-token
      - name: docker.io/giantswarm/docker-kubectl
        newName: giantswarm/docker-kubectl
    ```

- These are specific to `giantswarm` flux installation, and they doesn't exist in the `customer` one. Why? Because out helm chart is creating those resources with static names. If we add something like `{{ .Release.Name }}` to a name of each resource that is in this list, we won't have to run kustomizations at all, and `giantswarm` and `customer` installation will look the same. Example: https://github.com/giantswarm/flux-app/blob/faa5f89120c052b3d5850504a5ed86ab93b89b55/helm/flux-app/templates/base/clusterrole-crd-controller.yaml
    ```
    - target:
        kind: ClusterRole
        name: crd-controller
      patch: |-
        - op: replace
          path: /metadata/name
          value: crd-controller-giantswarm
        - op: replace
          path: /rules/10/resourceNames/0
          value: flux-app-pvc-psp-giantswarm
    - target:
        kind: PodSecurityPolicy
        name: flux-app-pvc-psp
      patch: |-
        - op: replace
          path: /metadata/name
          value: flux-app-pvc-psp-giantswarm
    - target:
        kind: ClusterRoleBinding
        name: cluster-reconciler
      patch: |-
        - op: replace
          path: /metadata/name
          value: cluster-reconciler-giantswarm
    - target:
        kind: ClusterRoleBinding
        name: crd-controller
      patch: |-
        - op: replace
          path: /metadata/name
          value: crd-controller-giantswarm
        - op: replace
          path: /roleRef/name
          value: crd-controller-giantswarm
    ```

    Why is it better? Because kustomize won't make sure that one resource has `giantswarm` postfix in a name if it's referenced by another. So if we change the PSP name, but won't change it in the CR, we will have to notice it in the runtime. 
    If this value is set on the helm level, it can be tested with helm tools during the `CI`, and then we can be rather certain that names are correct everywhere. 
    Also since kustomize doesn't know anything about cluster API, it will try rendering the PSP patch everytime, and it means that this state of a file won't work on both 1.24 and 1.25.
    - If we remove the PSP patch now, it will break all the installation, because flux will start to create resources with wrong names, and there will be conflicts between two fluxes
    - If we keep it now, we will have to switch to another branch while upgrading kubernetes. It's not an expected behaviour, as I've heard from people trying to upgrade k8s. They expect the working state be always in the main branch.

- It can be handled on the helm chart level, even easier if we put CRDs to templates. But since we don't want it. We also can put it to manifests directly. Or it can be added as a `helm post-renderer kustomization`, if we want to keep patchingit with kustomize
    ```yaml
    - target:
        kind: CustomResourceDefinition
        name: ".*"
      patch: |-
        - op: add
          # https://github.com/kubernetes-sigs/kustomize/issues/1256
          path: /metadata/annotations/kustomize.toolkit.fluxcd.io~1prune
    ```

    **Why helm post-renderer is better than kustomize**

    Because helm-postrenderer that is applying kustomizations doesn't eliminate helm features, but just adds kustomize ones, while installing helm chart with kustomization eliminates helm features.

- The big one. It can be handled by helm post-renderred since I think we don't want to edit these args in the helm chart directly. If we don't mind setting args via values, I'd go with it.
    ```
    - target:
        kind: Deployment
        name: helm-controller
        namespace: flux-giantswarm
      patch: |-
        - op: replace
          path: /spec/template/spec/containers/0/args
          value:
            - --events-addr=http://notification-controller.$(RUNTIME_NAMESPACE).svc
            - --watch-all-namespaces=false
            - --log-level=info
            - --log-encoding=json
            - --enable-leader-election
            - --concurrent=12
    - target:
        kind: Deployment
        name: image-automation-controller
        namespace: flux-giantswarm
      patch: |-
        - op: replace
          path: /spec/template/spec/containers/0/args
          value:
            - --events-addr=http://notification-controller.$(RUNTIME_NAMESPACE).svc
            - --watch-all-namespaces=false
            - --log-level=info
            - --log-encoding=json
            - --enable-leader-election
    - target:
        kind: Deployment
        name: image-reflector-controller
        namespace: flux-giantswarm
      patch: |-
        - op: replace
          path: /spec/template/spec/containers/0/args
          value:
            - --events-addr=http://notification-controller.$(RUNTIME_NAMESPACE).svc
            - --watch-all-namespaces=false
            - --log-level=info
            - --log-encoding=json
            - --enable-leader-election
    - target:
        kind: Deployment
        name: kustomize-controller
        namespace: flux-giantswarm
      patch: |-
        - op: replace
          path: /spec/template/spec/containers/0/args
          value:
            - --events-addr=http://notification-controller.$(RUNTIME_NAMESPACE).svc
            - --watch-all-namespaces=false
            - --log-level=info
            - --log-encoding=json
            - --enable-leader-election
    - target:
        kind: Deployment
        name: notification-controller
        namespace: flux-giantswarm
      patch: |-
        - op: replace
          path: /spec/template/spec/containers/0/args
          value:
            - --watch-all-namespaces=false
            - --log-level=info
            - --log-encoding=json
            - --enable-leader-election
    - target:
        kind: Deployment
        name: source-controller
        namespace: flux-giantswarm
      patch: |-
        - op: replace
          path: /spec/template/spec/containers/0/args
          value:
            - --events-addr=http://notification-controller.$(RUNTIME_NAMESPACE).svc
            - --watch-all-namespaces=false
            - --log-level=info
            - --log-encoding=json
            - --enable-leader-election
            - --storage-path=/data
            - "--storage-adv-addr=source-controller.$(RUNTIME_NAMESPACE).svc"
    ```

    - It's used to break kyverno, and once it's applied kyverno will block kustomize-controller, because expcetion policies won't be installed since we're not using helm. Adding policy exception all the time would mean that flux depends on kyverno, and it means that we depend on another team.
    ```
    - patch-pvc-psp.yaml
    - patch-kustomize-controller.yaml
    ```

- Resource that are added to a chart, that could be handled by helm.
    ```
    - resource-rbac.yaml
    - resource-refresh-vault-token.yaml
    ```

But this is the very base level, so if we go further, we'll see that we also have provider specific kustomizations, that are in most cases are used only to create one `ConfigMap`. It also can be handled by helm, if we add one manifests to templates.

So how one is supposed to upgrade k8s atm?

- Release a new flux version that supports both `PSP` and non `PSP` modes.
- Create a new branch in the `cmb` repo, remove everything `PSP` related from that and upgrade the flux version.
  Why can't we just update it? Because currently we expect flux to have PSPs deployed if k8s version is lower than 1.25. And hence we need to have PSP patches. 
- Edit the `GitRepository/cluster-management-fleet` so it's pointed to some branch of the `$CLUSTER-management-cluster repo`
  > How's that done is still myster to me, the easiest way that I see is to update this resource in place, and set an annotation that will make flux stop reconciling this repo. But it requires some deepere Flux knowledge, that we shouldn't expect from teams if they are not resposible for flux.
- In the `$CLUSTER-cluster-management` update a line of kustomization code. A part that is resposible for getting the provider's kustomization from the `cmb`

Also, we have this ~~weird~~ concept of switches. They work for most of apps, because they are using the `config` repo for getting values, but it won'r work for `flux`, because it's not an `app`. So values will have to be updated in the base `kustomization`. Since `kustomize` doesn't know anything about K8s, it will have to be a manual work that will have to be done for every cluster. 

**Will it be easier with my PR merged?** 
To be honest, no, because we will have to migrate to `HelmRelease` first. But once we're there, it will behadnled by `helm-controller`. Once k8s reaches 1.25, `helmrelease` will stop having `PSPs`. No switches, no edit in kustomizations, nobody should even touch our repos. You only need to have `flux` as a helm release.

So I'd say, **yes**, it's going to be extremely simple, once we reinstall flux.

---

**How to get there?**

There will be several steps required to get there. 
1. We need to modify the helm chart, so it has everything that we need, all the resources, that are added on all the kustomization layers. Once it can be configured with values, we can ket moving
2. Our `cmb` kustomization should install a `HelmRelease` instead of everything it's doing now. Then we will be able to keep using the current structure for a time being. 
  If we have a `HelmRelease` and `HelmRepository` created by the root kustomization, we can modify them in `$C-mc` repos with patches.
  Values can be set via `ConfigMaps`, that are created manually, and then added to the kustomization atm.
3. We need to update the bootstrap script for flux. For a time being it can do the following:
    ```console
    # -- It's important to have the same app name and namespace, so it will taken over by flux
    helm install flux-giantswarm -n flux-giantswarm gs-catalog/flux-app
    ```
4. Apply a cluster-level kustomization, that will create `HelmRelease`, `HelmRepository`, and `ConfigMap` so `flux` manages itself.


What we need to have at this point?

`GitRepository` that is pointing to the `$CLUSTER-management-clusters`
`Kustomization` that is created from the `$CLUSTER-management-clusters/flux-app/kustomization.yaml`
This `Kustomization` should point to the `cmb/bases/flux-app-v2/kustomization.yaml`
And the `cmb` kustmoization should create `HelmRepository`, `HelmRelese`, and `ConfigMap` with values.

Bootstrapping part can be using the `cmb` repo to get the real flux data:
- name
- namespace
- version

**How hard it is?**
I would say it's not hard. It will requires several steps to be done
- Move resources from kustomize to helm
- Moving customer/provider specific data to configmaps. It can still be kustomize that patches the default configmap.
- Updating the cluster-management-bases repo, we need to change what's kustomization is installing
- Update every cluster repo (this one is big, because we have a lot ot them, but it's going to be copy-paste) 

After it's done, we are not blockers for the k8s upgrade anymore.

> Technically, we're not blocking anybody already now, but I'm not sure that my workaround works on new clusters, and is not breaking everything. To test it I'll have to go throug the mc-bootsrap process and see if it's working or not. And it's not really solving the main issue about removing kustomize patches if the cluster is 1.25. Since we use `GitOps` we are expected to have the real state in the main branch, and this state is expected to work on every clusters, so teams don't have to take care of working on these repos. This is not possible atm. It will be fixed
> Though, it can be fixed by releasing my `Flux-app` PR without migrating to `HelmRelease`, because we will be able to get rid of PSP patches, and `kustomize` will not be broken anymore. 

---

### What's next?

Having this setup would mean that we have to manage all these `giantswarm-management-cluster/$CLUSTER/*` and related, maintained by hands. But what is going to be actual difference between them? Only values mostly. They all are going to look more or less like that

```
HelmRepository/gs-catalog
HelmRelease/flux-giantswarm
ConfigMap/flux-values
```

**So what can we do?**

We can have one repo, that is managed by us, let it be `cluster-management-bases` for a time being.

And have a script or a tool that is managing others.

Here comes my hiring task, and it's not a solution that is ready to use without a couple of modifications, but I'll put it here as an example. 

The source code is here: https://git.badhouseplants.net/allanger/shoebill/src/branch/init
It's a subject to change, so let's focus on what it's doing first.

Some features are still missing atm, so I'll show what it's supposed to do, and then we can decided whether we want it or not. 

The main idea of this tool is that one has a config defined in one place, and then after some magic this config is delivered to `GitOps` repos. 

You can find an example of this config in the `./examples/cluster-management-bases`. Please, keep in mind,that the `chart` property shouldn't be there, it's a failed attempt of adding a feature that won't be added. 

> The tool's called `shoebill`, so don't get confused when you see it in commands

Under `cluster` property we are defining GetOps repos, where each repo is supposed to be used by one cluster, hence it's `clusters`

`releases` and `repositories`, I guess, don't require any explanation.

So all we need to do, we need to have it transformed into `HelmRelease`, `HelmRepository`, and `ConfigMap`.

> We don't have to use this config and this tool, it's just an example of how it can be done. And also for some reason it seam not to work with GitHub, since I've migrated to the go-git. So in examples you can find my gitea. It also must be fixed obviously.

So, I don't assume you have my tool on your machine, so I'll describe what it's doing here.

It's iterating over all the `clusters`, pulling the repo that is chosen for the cluster, then it's going through releases that are chosen to be installed in that cluster, creating `HelmReleases` and `HelmRepository` out of them, then it's going through values and secrets and creating `ConfigMaps` and `Secrets` that will be also added to the repo. 

> Secrets are using sops and kustmozize-secret generator. you can provide a public sops key here, in the config.

After everything is generated, it's pushed to all the repos. And with couple of features we can install flux like that. Find an example of generated code in `./examples/cluster-config-example` 

> What I'll show now, is not supported atm, but I'm going to add it. 

Let's assume we have customers **customer-1** and **customer-2**, and both of them are deploying to **aws** and **azure**.

And let's also assume that customers have secrets that flux must have for some reason, and they don't want them to be shared. 

We should be able to create a config like that
```
repositoies:
  - name: gs-catalog
    url: ...
releases:
  - name: flux
    repository: gs-catalog
    values:
      - ./values/common/flux.yaml
      - ./values/providers/{{ vars.provider }}/flux.yaml
    secrets:
      - ./secrets/customers{{ vars.customer }}/flux.yaml
clusters:
  - name: cluster-a
    vars:
      customer: customer-1
      provider: aws
    git: $GIT_REPO_URL
    dotsops: |
      creation_rules:
        - path_regex: secrets/.*.yaml
          key_groups:
          - age:
            - $SOME_AGE_KEY
    provider: flux
    releases:
        - flux
  - name: cluster-b
    vars: 
      customer: customer-2
      provider: azure
      ...
  - name: cluster-c
  - name: cluster-d
    ...
    # I guess you can follow the logic
```

After we sync that config, we will have several repos with configs, that are fully managed with that tool. 

It means that flux can be fully managed from this file, and other teams, or us, when we need to test something, we can use this one repo to do it. No more kustmize-kustomizing-kustomizations.

> Again, it's only what I would expect from this tool atm, it doesn't work this way.

For example, if we need to update flux-version on one cluster we add a new release with a different version, or I expect to have overrides for releases per cluster, so two examples
```yaml
# Current way
releases:
  - name: flux
    repository: gs-catalog
    version: 1.0.0
    values:
      - ./values/common/flux.yaml
      - ./values/providers/{{ vars.provider }}/flux.yaml
    secrets:
      - ./secrets/customers{{ vars.customer }}/flux.yaml
  - name: flux-new
    release: flux
    repository: gs-catalog
    version: 1.0.1
    values:
      - ./values/common/flux.yaml
      - ./values/providers/{{ vars.provider }}/flux.yaml
    secrets:
      - ./secrets/customers{{ vars.customer }}/flux.yaml
clusters:
  - name: cluster-old-flux
    releases:
      - flux
  - name: cluster-new-flux
    releases:
      - flux-new
---
# A better way
releases:
  - name: flux
    repository: gs-catalog
    version: 1.0.0
    values:
      - ./values/common/flux.yaml
      - ./values/providers/{{ vars.provider }}/flux.yaml
    secrets:
      - ./secrets/customers{{ vars.customer }}/flux.yaml
clusters:
  - name: cluster-old-flux
    releases:
      - flux
  - name: cluster-new-flux
    releases:
- release: flux
        version: 1.0.1
```

If we have this there will be only one repo to be managed. So once a new cluster is created, we can have an automated repo creation for that one, and the we need to add a `cluster` property to this config. Since it's not being reconciled all the time, it can be added to a branch, and rolled-out only for that specific cluster. To make sure it's bootsrapped correctly.

Managing the config will become a matter of updating one yaml file. And once cluster's tested, it can be just merged. 

Instead of creating a branch in two repos, modifying kustomizations in both of them in order to get the desired state. 

For example:

Currently, to create a cluster and install non-default flux version, we need to create a branch in `cmb` repo, create a brach in `giantswarm-management-clusters` add a new folder there, put kustmization there, set it to be wathching a correct branch of the `cmb`, and update the `cluster-management-fleet` in the cluster. 

> This folder will contain the main Kustomization that is not being updated automatically, and is just created out of a template during the bootstrap, that I find a huge anti-pattern. Because once we need to add a change to that kustomization, we will have to go through every `$CUSTOMER-management-cluster/$CLUSTER` and edit kustomizations there as well. If we replace those config with generated code, they will be kept up-to-date by us managing the main config file.

Since this tool is pretty simple, it's just an automation for cli commands, and also can be a script, it shouldn't become a pain to maintain. This config doesn't require any deep knowledge of anything, and the generated code also is very simple and contains only four kinds of resources. 

So I think even if we only moving `flux` to a setup like that, it's already becoming easier.

#### Other improvements

There are more improvements that I would propose, that are coming out of what's written above.

1. **Flux root resources**
   To make flux manage itself, we need to create a `HelmRelease` resource. To avoid `Kustomization` creatiin during the bootstrap, we can wrap it with helm, and install it after `flux` is installed. Check the example in `./examples/charts/root`. As you see I'm creating two `GitRepositories` and `Kustomizations`. It is supposed to let us switch branches of the repos with generated code when we need to debug something, without risking to lose the main `Kustomization`.
   Both of them can be handled by the `shoebill` config, if we just put the root kustomization as another cluster.
   ```yaml
   releases:
    - name: root
      repository: badhouseplants-oci
      chart: root
      version: 0.1.5
      namespace: flux-giantswarm
      values:
        - ./root/values.yaml
   clusters:
    - name: root-config
      git: git@git.badhouseplants.net:giantswarm/root-config.git
      provider: flux
      releases:
        - root

    - name: cluster-shoebill-test
      git: git@git.badhouseplants.net:giantswarm/cluster-example.git
      dotsops: |
        creation_rules:
          - path_regex: secrets/.*.yaml
            key_groups:
            - age:
              - age16svfskd8x75g62f5uwpmgqzth52rr3wgv9m6rxchqv6v6kzmzf0qvhr2pk
      provider: flux
      releases:
        - flux-giantswarm
    ```
    And once we have it in the config, we can add another step to the bootstrap, so it's installed as a halm chart. Then after it's bootstrapped, we will have flux managed by itself, and only thing that we really should be taking care if is this config repo.

2. **Namespace management**
   Namespaces can be managed by helm too, check the example in `./examples/charts/namespaces`. We can install namespaces with helm during the bootsrap, and then make flux manage it. So once we need to add a namespace to clusters, they will automatically be added to all the new clusters too.

3. Other apps. Currently, we are using apps-operator for managing apps. And to be honest to me it only looks like we're adding a layer of complexity, because after all it's creating a `HelmRelease`. We can migrate apps from the catalog, to the main config. And taking under consideration that two steps above are applied, once a new cluster is bootstrapped, all the apps are going to be installed by the `root` kustomization, and they can be managed by other teams in the config repo. 

4. Use helmfile instead `install-something.sh` scripts. Since with that setup, flux is instlled almost in the very beginning, we can have the whole bootstrap looking like that
    - Create a cluster (it's something that I'm not covering at all, but I assume we're using k8s eveywhere, so we are supposed to have more or less the same API available after this step is ready)
    - Install namespaces
    - Install system stuff into clusters (CNI, CoreDNS)
    - Install flux
    - Install the root kustomization

    So the whole bootstrap after the first step can be put in one helmfile, instead of tons of scripts. Check the `./helmfile.yaml` and the `./bootstrap.sh` to see what I mean.
    I'm not installing CNI and CoreDNS here, but if they are installed as helm charts, they can also be put in that helmfile, most probably.
    Also, instead of running `helmfile apply` several times, we can add the `needs` property to build the requirenments chain and run it only once. And after the `root` release is installed, flux is taking the control over.
    If helmfile entries have corresponding releases in the config, they will also be taken over by flux.

    As you see I'm cloning the repo with configs, and using values from it. 
