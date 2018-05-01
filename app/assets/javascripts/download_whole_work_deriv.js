$( document ).ready(function() {

  // A JS 'class' for handling download UI

  function ChfOnDemandDownloader(work_id, type) {
    this.work_id = work_id;
    this.deriv_type = type;
  }

  ChfOnDemandDownloader.prototype.fetchForStatus = function() {
    var _self = this;

    fetch("/works/" + this.work_id + "/pdf").then(function(response) {
      return response.json()
    }).then(function(json) {
      if (json.status == "success") {
        _self.getModal().modal("hide");
        window.location = json.url;

      } else if (json.status == "in_progress") {
        _self.getModal().modal("show");
        // wait, then check again....
        _self.nextFetch = setTimeout(function() {
          _self.fetchForStatus();
        }, 2000);
      } else {

      }
    }).catch(function(error) {
      debugger;
      1+1;
    });
  };

  ChfOnDemandDownloader.prototype.getModal = function() {
    var _self = this;

    if (this.modalElement) {
      return this.modalElement;
    }
    //create a new bootstrap modal
    var modalEl = $('\
      <div class="modal on-demand-download" role="dialog"> \
        <div class="modal-dialog" role="document">\
          <div class="modal-content">\
            <div class="modal-body">\
            <p>Preparing your download, may take a bit.</p>\
            <div class="progress progress-striped active">\
              <div class="progress-bar"  role="progressbar" aria-valuenow="100" aria-valuemin="0" aria-valuemax="100" style="width: 100%">\
              </div>\
            </div>\
            </div>\
            <div class="modal-footer">\
              <button type="button" class="btn btn-default" data-dismiss="modal">Cancel</button>\
            </div>\
          </div>\
        </div>\
      </div> \
    ');
    $("body").append(modalEl);

    modalEl.modal({
      backdrop: "static",
      show: false
    });

    // make sure any fetches get cancelled if modal is cancelled.
    modalEl.on('hidden.bs.modal', function (e) {
      if (_self.nextFetch) {
        clearTimeout(_self.nextFetch);
        _self.nextFetch = null;
      }
    })

    this.modalElement = modalEl;

    return this.modalElement;
  };

  ChfOnDemandDownloader.prototype.initiate = function() {

  };


  $(document).on('click', '*[data-download-deriv-type]', function(e) {
    e.preventDefault();

    var type = $(e.target).data("download-deriv-type");
    var id   = $(e.target).data("download-whole-work-deriv");

    var downloader = new ChfOnDemandDownloader(id, type);
    downloader.initiate();

    downloader.fetchForStatus();

  });
});