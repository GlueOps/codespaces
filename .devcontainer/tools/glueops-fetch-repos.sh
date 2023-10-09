glueops-fetch-repos() {
    #https://stackoverflow.com/a/68770988/4620962
    
    gh repo list $(git remote get-url origin | cut -d/ -f4) --no-archived --limit 1000 | while read -r repo _; do
      gh repo clone "$repo" "$repo" -- --depth=1 --recurse-submodules || {
        git -C $repo pull
      } &
    done
}
