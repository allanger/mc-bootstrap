# New bootstrap

> Before you start reading it. All you will find here is my opinion, so treat it as that please.
> It's a list of improvements that are supposed making out life easier (not only honeybadger, but other's as well)

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
1. PSP and related RBAC now live in a separate tempalte, because they are not shipped with the official `install.yaml` anymore
2. PSP and related RBAC are now wrapped by a K8S version check:
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
3. All the CRs are wrapped by corresponding API checks
    ```mustache
    {{- if .Capabilities.APIVersions.Has "autoscaling.k8s.io/v1/VerticalPodAutoscaler" }}
    {{- end }}
    ```
    Because flux is supposed to manage cluster and all (or almost all) the resources in the cluster, we need to have it deploed to a cluster a soon as possible. Flux itself doesn't depend on any of those `CRs`. It's something that is added by us.
## Flux app

### What are problems?

---

#### Upgrading to 1.25 without workarounds is not possible

It's not possible, because flux is installed with kustomize, that doesn't support api checks. So after PSPs are removed from API, kustomization that is installing flux is broken.

Current workflow is to add a new `if` condition to the chart, that will check for a certain value set `podSecurityStandards` and enable/disable PSPs installation.

It requires (not a lot):
- Change in the helm chart
- Release

But then we need to install that version to clusters. Since we need to test the whole upgrade process, we need co create a branch in the `cluster-management-bases` and then point `$CLUSTER-management-cluster` customization to the correct brahcn of `cluster-management-bases`. Since it's a matter of testing, each iteration requires:

- Helm-chart change
- Release
- Change to the `cluster-management-bases`
- Change to the `$CLUSTER-management-cluster`

More precisely (in a clean way):
- Update the helm chart
- Release a new version
- Edit the main flux kustomization in the `cmb`, so it' installing another flux version
- We need to add a patch for the `GirRepository/cluster-management-fleet` so it's creating a fleet out of the correct branch, or we can edit the manifest in place, both ways requires understanding of how flux works, second requires understanding of flux annotations. And since Flux is Honeybdager's responsibillity, we shouldn't expect that knowleges from a anybody else. So everytime there somebody has a problem, it's us being triggered.
- After cluster-management-fleet is using a correct branch, we need to update the branch that is installing `flux-app-v2` in kustomizations of `$CLUSTER-management-cluster`. Since the default `GitRepositoty/cluster-management-fleet` is created by `cmb`, and then we reference a `cmb` branch in the `$CLUSTER-management-cluster` repo, it's already a chicken-egg condition. And the easiest solution that is editing in place is vialoting GitOps principles.

Since flux app is not managed as an app, it can't be configured via the `config` repo, but as I've seen it's considered a default way of managing values, so it's already a behavior that is not expected by others. And it reuires others to get deeper in our setup.

Since the spread of editing the main branch of the `cmb` is huge, we can't just go ahead an replace it there, also clusters are being updated one-by-one, ones who are upgrading will have to figure out a way to upgrade using two repos for each cluster + the default `config` repo for the rest of apps, because this value (that enables/disables PSPs) must be set manually.

**What is that value is doing in out chart?**
It's enables/disables PSP creating and RBAC for that PSP too.

**When should PSPs be not installed?**
After a cluster version is higher that 1.25

**What is the helm solution for that?**

```
{{- if le (atoi (.Capabilities.KubeVersion.Minor | replace "+" "")) 24 }}
kind: PodSecurityPolicy
...
{{- end }}
```

If we have this change, we will be able to deploy the same version of out helm chart to both `1.24` and `1.25` wiothout any manual change. Since the expected behaviour is to have PSPs until 1.25, it's fixing this problem for us.

Workflow
- Release it
- Deploy it everywhere
- We have PSPs installed without modidifying any values everywhere

Then if somebody is testing the cluster upgrade process, they only need take care of other apps, no changes are required to `cmb` and `$CLUSTER-management-cluster` repos. They only touch the `config` one to set that value evrywhere.

**Why won't it work?**
Because kustomize is not able to run API checks. Once an API check is defined in a chart, kusomize won't render that manifest at all, so we won't have PSP.

**Solution?...**
Helm is a self-efficient tool, it doesn't need to have a kustomize, because it's a templater on its own.

Let's have a look at what our kustomizations are doing

- It's already handle by values, we can set it via them.
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

Why is it better? Because kustomize won't make sure that one resource has `giantswarm` postfix in a name if it's being refenreced by another. So if we change the PSP name, but won't change it in the CR, we will have to notice it in the runtime. If this value is set on the helm level, it can be testes with helm tools, and then we can be rather certain that names are correct everywhere. Also since kustomize doesn't know anything about cluster API, it will try rendering the PSP patch everytime, and it means that this state of a file won't work on both 1.24 and 1.25.
If we remove the PSP patch now, it will break all the installation, because flux will start to create resources with wrong names, and there will be conflicts between two fluxes
If we keep it now, we will have to switch to another branch while upgrading kubernetes. It's not an expected behaviour, as I've heard from people trying to upgrade k8s. They expect the working state be always in the main branch.

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
resources:
```

- Resource that are added to a chart, that could be handled by helm.
```
- resource-rbac.yaml
- resource-refresh-vault-token.yaml
```

But this is not a real kustomization that is being used by a "$CLUSTER-cluster-management", we use it by other kustomizations.

We are using kustomizations from `/bases/provider/$PROVIDER` that are in most cases are used only to create one `ConfigMap`. It also can be handled by helm, if we add one manifests to templates.

So currently the gitflow path looks like that (and don't forget about branching strategy):
```
$CLUSTER-management-cluster/kustomization -> cmb/providers/kustomizations -> cmb/flux/kustomizations
```

So what can be done with that?
If we stop installing flux with `Kustomization`, and replace it with `HelmRelease`, we will be able to have all these features included out of the box more or less.

So instead of:
```
$CLUSTER-management-cluster/kustomization -> cmb/providers/kustomizations -> cmb/flux/kustomizations -> GitRepository/cluster-management-fleet -> Kustomization/flux
```

We can have:

```
HelmRepository/gs-catalog -> HelmRelease/flux-app -> GitRepository/cluster-management-fleet -> Kustomization/flux
```

If we need to configures values, we can set them with configmaps on the `Kustomization/flux` level. And use them in `HelmRelease/flux-app`. It's what was done by me as my hiring tasl, and we can have it automated easily with no problems.

After flux-app is managed by helmrelease instead of kustomize, upgrade of a cluster will be upgrade of a k8s version. Since templates are generated dynamically, after we upgrade a version, helm-controller should stop rendering PSPs, and there will bo no chagnes required to any of GitOps repos.

---

#### Flux-app refactoring

So as you could see in the previous block, it requires some changes in the flux-app helm chart.

You could see the whole list of changes here: https://github.com/giantswarm/flux-app/pull/241/

These changes are not only related to the helm-controller requirenments, but also they are supposed to make changes easier in the future.

---

#### How to install flux?

> Here the bootstrap thing is started

If we want to replace kustomize with flux, we will most probabaly apply some changes to the bootstrappging.

Flux requires only several components to be installed in the cluster: for example CNI and CoreDNS.

But flux doesn't requires Kyverno and VPA to be running. Even though security team may argue, a cluster (that only contains Flux, CNI, and CoreDNS) doesn't really have anything to be secured. Aslo, taking under consideration that flux-app us managed by us, we can be more or less sure that it's secure enough to be running without kyverno for 5 minutes without security issues.

Currentlly, we don't want to edit mc-bootsrap script, we only want to isntall flux ina different way. So let's replace that part only.

Since we want flux to be managed by the same flux later, we will have to install it with helm and then create a `HelmRelease` resource.

Currently, we have to kustomizations that are installing flux.
1. CRDs
2. Flux-app

We need to install CRDs before flux, becase flux needs to have them to be installed and start managin itself.

Instead. we can install `Flux` with CRDs during the bootstrap.

What I'm proposing might not seem easier that what we have now, but I'll explain it later.

**What do we need to do?**

- Install flux
- Make flux manage itself


**How to install flux?**

I would suggest having a helmfile in the bootstrap repo, that is being synced on bootstrap

```yaml
repositories:
  - name: gs-catalog
    url: https://giantswarm.github.io/giantswarm-catalog/
releases:
  - name: flux-app
    chart: gs-catalog/flux-app
    version: $SOME_VERSION
```

After we sync that helmfile against a cluster, we don't have it managing itself. We will have to create a `Kustomization` that will manage a `HelmRelease`.

So there are different ways of getting there. The easiest one that wouldn't be a big problem to implement, would be adding a `HelmRelease` in the `management-cluster-bases` repo and add a kustomization that will install it.

So we have a `flux` kustomization that instead of installing flux as a kustomization, it's going to apply a `HelmRelease`.

At this point we can keep using kustomizations without breaking things. We will just replace flux `Kustomization` with `Flux` `HelmRelease`

**But we are adding an extra step, aren't we?**

Yes, at this point we are. And it seems to be more complex that it was before.

So let's check what that kustomization that is installing `HelmRelease` is.

It should contain 3 types of resources:

- HelmRepository
- HelmRelease
- ConfigMap with values
- (optional) Secret with secret values

Where `HelmRepository` is always the same, :w


2. Flux requires a lot of CRDs to be installed, that produces a chicken-egg problem
3. (IMO) Maintaining the chart is painfull.

### How to solve them?

# A new bootstrap and new config management

## Bootstrap

Creating a cluster should not take more that ~10 minutes, and it should never be so complicated,
that one is constantly repeating that creating a cluster `is very challenging`, because it's not
a challenge, to manage k8s, especially for a company that is selling k8s.

Why is it a challenge now?

1. Helm charts are not using helm features to reduce installation complexity
2. Kustomize, kustomize, kustomize
3. Bootstrapping scipts seem to never be refactored
4. A lot of sources of configs, when it should be just one

Now let's go step by step

1. ---

Since we don't use ArgoCD, we're actually able to use helm features

- Helm can check the k8s version, and it would save use PSP upgrade pain.
- Helm can check which APIs are available in a cluster, and it save us from bootstrapping pain

API check vs Switch Flag

Currenrly, to upgrade to 1.25, we need to have a release with some value property set to true that wouldn't make it render PSP, and then upgrade.

> My guess would be that it's there because helm is no used for installing helm charts, but since we're using flux, I'm not sure.

If we add `{{- if le (atoi (.Capabilities.KubeVersion.Minor | replace "+" "")) 24 }}`, helm-controller will not try to deploy PSPs anymore, once we're on 25.

That's it, we don't need to switch anything, it's done by helm. If we need to ensure `security standards`, it's not a helm responsibillity, but kyverno's
If our chart is not satisfying kyverno, we need to upgrade the chart, but it's not a matter of an additional switch anymore.

Flux-app has a lot of CR bundled, and because of that we have an insane bootstrap, that is installing all the CRDs to the cluster, so flux can be installed.

Since flux is managing a cluster, it should come right after all the system resources are installed, and VerticalPodAutoscaled and Kyverno are not system resources
So flux must not depend on any of those CRs, that's why we're adding `{{- if .Capabilities.APIVersions.Has "autoscaling.k8s.io/v1/VerticalPodAutoscaler" }}`

Now helm will check, if vpa can be installed before firing its manifests against the cluster api

If all our charts have this, they are independant but they're still using all the features that we want them to use, if they're available

2. ---

> Kustomize is always becoming a hell, I've never seen an exception

What to do with kustomize? It depends on what it's supposed to be doing.
If it's creating a resource, it should be a part of a chart. Because managing kustomization will become eventually to complicated, I suggest modifying chart every time we need to have an additional resource.
If it's pathcing a resource and it can't become a part of a chart, we can use post-render kustomization that is supported dy flux.

But a halm chart is a bundle that should be installable and self-sufficient. That's why it's a package manager, and not just a tempalter

3. ---
There must be no `helm install` in bootstarp scripts, because it's unmaintaineble, compliated and absolutely not required. Since we use flux, we need to use flux to isntall helm releases. If we need charts to be installed before flux is there, we should make it easier to maintain, and though it's not part of our responsibillity, I'd just suggest a change to teams that are resposible for that.

Instead of using
```
helm install $RELEASE $REPO/$CHART --version $VERSION \
  --set $SOMETHING=$SOMETHING
  -f $SOME_FILE
helm install $RELEASE $REPO/$CHART --version $VERSION \
  --set $SOMETHING=$SOMETHING
  -f $SOME_FILE
helm install $RELEASE $REPO/$CHART --version $VERSION \
  --set $SOMETHING=$SOMETHING
  -f $SOME_FILE
```

we can use helmfile during the bootstrap
```yaml
repositoies:
  - name: $REP
    url: $URL
releases:
  - name: $RELEASE
    chart: $REPO/$CHART
    version: $VERSION
    values:
        - $PATH_TO_VALUES
  - name: $RELEASE
    chart: $REPO/$CHART
    version: $VERSION
    values:
        - $PATH_TO_VALUES
  - name: $RELEASE
    chart: $REPO/$CHART
    version: $VERSION
    values:
        - $PATH_TO_VALUES
```

In case, maintainers want their releases to be also managed by flux, they have to use same name and namespaces, and it's better to use same values and versions. Then we can take them over with no troubles

But what about namespaces and flux resources?

I suggest using helm here too, it's going to be two simple as heck helm charts, that will be able to handle the whole config. So let's come up with a real example of a helm file

