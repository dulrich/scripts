
import scipy.stats as sps


class SData():
	name = "sdata obj"
	mu = None
	sd = None
	
	def __init__(self, data=None):
		self.patch(data)
	
	def patch(self, data):
		if data is not None and type(data) is dict:
			fields = [
				"name",
				"mu",
				"sd",
			]
			for field in fields:
				if field in data:
					setattr(self, field, data[field])


def cohort_cdf(obj, cohort=100, vals=[]):
	dist = sps.norm(loc=obj.mu, scale=obj.sd)
	for v in vals:
		cdf=dist.cdf(v)
		#cdf_round=round(cdf, 3)
		cnt = cohort * (1 - cdf)
		cnt = round(cnt, 3)
		print(f"{obj.name} {v}: {cnt}")


