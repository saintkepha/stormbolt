(function($) {
     $.fn.serializeFormJSON = function() {

         var o = {};
         var a = this.serializeArray();
		 var str = '';
         $.each(a, function() {
					str += this.name+' ';
                    if (o[this.name]) {
                        if (!o[this.name].push) {
                            o[this.name] = [o[this.name]];
                        }
                        o[this.name].push(this.value || '');
                    } else {
                        o[this.name] = this.value || '';
                    }
                });
         return o;
     };
 })(jQuery);
