FROM google/golang:1.4

EXPOSE 8080

RUN apt-get install -y --no-install-recommends graphviz

# Manually fetch and install gddo-server dependencies (faster than "go get").
ADD https://github.com/garyburd/redigo/archive/779af66db5668074a96f522d9025cb0a5ef50d89.tar.gz /x/redigo.tar.gz
ADD https://github.com/golang/snappy/archive/a911026e1ffa84898778ccb0363930485e0aa880.tar.gz /x/snappy.tar.gz
RUN tar xzvf /x/redigo.tar.gz -C /x && tar xzvf /x/snappy.tar.gz -C /x && \
	mkdir -p ${GOPATH}/src/github.com/garyburd && \
	mkdir -p ${GOPATH}/src/github.com/golang && \
	mv /x/redigo-* ${GOPATH}/src/github.com/garyburd/redigo && \
	mv /x/snappy-* ${GOPATH}/src/github.com/golang/snappy && \
	rm -rf /x

# Create a shim runner to leverage environment variables
COPY script/gddo /usr/local/bin/

# Build the local gddo files.
COPY . ${GOPATH}/src/github.com/golang/gddo
RUN go install github.com/golang/gddo/gddo-server

# How to start it all.
CMD ["gddo"]
